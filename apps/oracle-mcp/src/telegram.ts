// Telegram bridge for the Oracle chat (juancode-c6y). Lets Juan chat with Oracle
// from Telegram using the EXACT SAME backend as the browser console: every incoming
// message is routed through `oracleChat` (oracle.ts → headless `claude -p` with
// `--resume`), the same call `/api/chat` makes. No agent logic is forked here — this
// module is purely a Telegram front-end + per-chat session plumbing.
//
// Transport is long-poll `getUpdates` (no webhook), so it works behind the existing
// cloudflared `oracle` tunnel without exposing an inbound port. On startup, if
// TELEGRAM_BOT_TOKEN is unset the bridge is a no-op; ALLOWED_USER_IDS is the allowlist
// of Telegram user ids permitted to talk to it (anyone else is ignored). Each Telegram
// chat keeps its own `claude` session id (telegram-store.ts), separate from the browser
// thread; `/new` (or `/start`) resets it. Replies are chunked to Telegram's 4096-char
// per-message limit.

import {
  clearTelegramSession,
  getTelegramSession,
  setTelegramSession,
} from "./telegram-store.ts";
import { oracleChat, type ChatReply } from "./oracle.ts";

/** Telegram's hard per-message character cap. We chunk below it to stay safe. */
const TELEGRAM_MAX_CHARS = 4096;
const CHUNK_LIMIT = 4000;

export interface TelegramConfig {
  token: string;
  /** Empty set ⇒ no one is allowed (the bridge logs a warning and ignores all). */
  allowedUserIds: Set<number>;
}

/** Read the bridge config from the environment. Returns null when TELEGRAM_BOT_TOKEN
 *  is unset, which the caller treats as "bridge disabled". ALLOWED_USER_IDS is a
 *  comma/space-separated list of numeric Telegram user ids. */
export function readTelegramConfig(env: NodeJS.ProcessEnv = process.env): TelegramConfig | null {
  const token = (env.TELEGRAM_BOT_TOKEN ?? "").trim();
  if (!token) return null;
  return { token, allowedUserIds: parseAllowedUserIds(env.ALLOWED_USER_IDS) };
}

/** Parse "5547517536, 123" → Set{5547517536, 123}. Ignores blanks/non-numerics. */
export function parseAllowedUserIds(raw: string | undefined): Set<number> {
  const ids = new Set<number>();
  if (!raw) return ids;
  for (const part of raw.split(/[\s,]+/)) {
    if (!part) continue;
    const n = Number(part);
    if (Number.isInteger(n)) ids.add(n);
  }
  return ids;
}

/** Whether a Telegram user id may use the bridge. An empty allowlist denies everyone. */
export function isAllowed(userId: number, allowed: Set<number>): boolean {
  return allowed.has(userId);
}

/** Split a reply into Telegram-sized chunks, preferring to break on newline
 *  boundaries and hard-splitting any single line longer than the limit. Always
 *  returns at least one (possibly empty-→placeholder) chunk. */
export function chunkMessage(text: string, limit = CHUNK_LIMIT): string[] {
  const max = Math.min(limit, TELEGRAM_MAX_CHARS);
  const trimmed = text ?? "";
  if (trimmed.length <= max) return [trimmed];
  const chunks: string[] = [];
  let current = "";
  for (const line of trimmed.split("\n")) {
    // A single oversized line: flush, then hard-split it.
    if (line.length > max) {
      if (current) {
        chunks.push(current);
        current = "";
      }
      for (let i = 0; i < line.length; i += max) chunks.push(line.slice(i, i + max));
      continue;
    }
    const candidate = current ? `${current}\n${line}` : line;
    if (candidate.length > max) {
      if (current) chunks.push(current);
      current = line;
    } else {
      current = candidate;
    }
  }
  if (current) chunks.push(current);
  return chunks.length > 0 ? chunks : [""];
}

// ── Telegram update shapes (only the fields we use) ──────────────────────────

interface TgUser {
  id: number;
}
interface TgChat {
  id: number;
}
interface TgMessage {
  message_id?: number;
  chat?: TgChat;
  from?: TgUser;
  text?: string;
}
export interface TgUpdate {
  update_id: number;
  message?: TgMessage;
}

/** Pull the well-formed `(chatId, userId, text)` out of an update, or null if it's
 *  not a text message we can act on (edits, photos, joins, etc. are ignored). */
export function parseTextMessage(
  update: TgUpdate,
): { chatId: number; userId: number; messageId: number | null; text: string } | null {
  const msg = update.message;
  const chatId = msg?.chat?.id;
  const userId = msg?.from?.id;
  const text = msg?.text;
  if (typeof chatId !== "number" || typeof userId !== "number") return null;
  if (typeof text !== "string" || !text.trim()) return null;
  const messageId = typeof msg?.message_id === "number" ? msg.message_id : null;
  return { chatId, userId, messageId, text: text.trim() };
}

/** The side-effecting collaborators the update handler needs. Injected so the handler
 *  is unit-testable without a real Telegram API or `claude` process. */
export interface TelegramDeps {
  chat: (text: string, sessionId: string | null) => Promise<ChatReply>;
  getSession: (chatId: number) => Promise<string | null>;
  setSession: (chatId: number, sessionId: string) => Promise<void>;
  clearSession: (chatId: number) => Promise<void>;
  send: (chatId: number, text: string) => Promise<void>;
  /** Best-effort "typing…" chat action; never throws (a failed hint must not stall a reply). */
  typing: (chatId: number) => Promise<void>;
  /** Best-effort message reaction. `emoji === null` removes the reaction. Never throws. */
  react: (chatId: number, messageId: number, emoji: string | null) => Promise<void>;
}

/** The real collaborators, wired to the shared Oracle backend + per-chat store. */
function defaultDeps(token: string): TelegramDeps {
  return {
    chat: (text, sessionId) => oracleChat(text, sessionId),
    getSession: getTelegramSession,
    setSession: setTelegramSession,
    clearSession: clearTelegramSession,
    send: (chatId, text) => sendMessage(token, chatId, text),
    typing: (chatId) => sendChatAction(token, chatId, "typing"),
    react: (chatId, messageId, emoji) => setMessageReaction(token, chatId, messageId, emoji),
  };
}

/** Handle one update: enforce the allowlist, route `/new` + `/start` to a session
 *  reset, and send everything else through the shared Oracle backend, persisting the
 *  returned session id so the chat stays continuous. Non-allowed users are ignored
 *  (logged, no reply) so the private bot doesn't announce itself to strangers. */
export async function handleUpdate(
  update: TgUpdate,
  allowed: Set<number>,
  deps: TelegramDeps,
): Promise<void> {
  const parsed = parseTextMessage(update);
  if (!parsed) return;
  const { chatId, userId, messageId, text } = parsed;

  if (!isAllowed(userId, allowed)) {
    console.warn(`telegram: ignoring message from non-allowed user ${userId}`);
    return;
  }

  const command = text.toLowerCase();
  if (command === "/new" || command === "/start") {
    await deps.clearSession(chatId);
    await deps.send(
      chatId,
      command === "/start"
        ? "👋 Oracle here. Send a message to start. /new resets this thread."
        : "🆕 Started a fresh Oracle thread.",
    );
    return;
  }

  // Immediate "Oracle is working" feedback before the (often slow) backend call: a 👀
  // reaction on the user's message plus a "typing…" chat action, refreshed every few
  // seconds since Telegram clears typing after ~5s. Both are best-effort and never throw.
  if (messageId !== null) await deps.react(chatId, messageId, "👀");
  await deps.typing(chatId);
  const typingTimer = setInterval(() => void deps.typing(chatId), 4000);

  const sessionId = await deps.getSession(chatId);
  let reply: ChatReply;
  try {
    reply = await deps.chat(text, sessionId);
  } finally {
    clearInterval(typingTimer);
    // Clear the working indicator now that the turn is done (typing stops on its own
    // once we send the reply, but the reaction must be removed explicitly).
    if (messageId !== null) await deps.react(chatId, messageId, null);
  }
  if (reply.sessionId) await deps.setSession(chatId, reply.sessionId);

  const body = reply.reply.trim() || "(no reply)";
  const out = reply.isError ? `⚠️ ${body}` : body;
  for (const chunk of chunkMessage(out)) await deps.send(chatId, chunk);
}

// ── Telegram HTTP API ────────────────────────────────────────────────────────

const apiBase = (token: string) => `https://api.telegram.org/bot${token}`;

/** Send a plain-text message (no parse_mode → no Markdown/HTML escaping pitfalls). */
async function sendMessage(token: string, chatId: number, text: string): Promise<void> {
  const res = await fetch(`${apiBase(token)}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`telegram sendMessage ${res.status}: ${detail.slice(0, 200)}`);
  }
}

/** Best-effort "typing…" chat action. Swallows failures: a missing typing hint must
 *  never stall or fail the actual reply. Telegram auto-clears it after ~5s or when we
 *  send a message, so there's nothing to undo. */
async function sendChatAction(token: string, chatId: number, action: string): Promise<void> {
  try {
    const res = await fetch(`${apiBase(token)}/sendChatAction`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, action }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      console.warn(`telegram sendChatAction ${res.status}: ${detail.slice(0, 200)}`);
    }
  } catch (e) {
    console.warn("telegram sendChatAction failed:", e instanceof Error ? e.message : e);
  }
}

/** Best-effort message reaction. `emoji === null` clears the reaction (empty array).
 *  Swallows failures (e.g. an emoji the chat disallows) — a decorative hint must never
 *  break message handling. */
async function setMessageReaction(
  token: string,
  chatId: number,
  messageId: number,
  emoji: string | null,
): Promise<void> {
  const reaction = emoji ? [{ type: "emoji", emoji }] : [];
  try {
    const res = await fetch(`${apiBase(token)}/setMessageReaction`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, message_id: messageId, reaction }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      console.warn(`telegram setMessageReaction ${res.status}: ${detail.slice(0, 200)}`);
    }
  } catch (e) {
    console.warn("telegram setMessageReaction failed:", e instanceof Error ? e.message : e);
  }
}

/** One long-poll `getUpdates` call (timeout=50s server-side), scoped to message
 *  updates. Returns the updates array (possibly empty). */
async function getUpdates(token: string, offset: number): Promise<TgUpdate[]> {
  const url = `${apiBase(token)}/getUpdates?timeout=50&offset=${offset}&allowed_updates=${encodeURIComponent(
    '["message"]',
  )}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`telegram getUpdates ${res.status}`);
  const data = (await res.json()) as { ok?: boolean; result?: unknown };
  if (!data.ok || !Array.isArray(data.result)) return [];
  return data.result as TgUpdate[];
}

/** Background long-poll loop: drain updates, advance the offset past each handled
 *  one, and isolate per-update failures so one bad message can't stall the loop.
 *  Backs off briefly on a poll error (e.g. transient network/Telegram outage). */
async function pollLoop(config: TelegramConfig, deps: TelegramDeps, signal: AbortSignal): Promise<void> {
  let offset = 0;
  while (!signal.aborted) {
    let updates: TgUpdate[];
    try {
      updates = await getUpdates(config.token, offset);
    } catch (e) {
      if (signal.aborted) return;
      console.error("telegram getUpdates failed:", e instanceof Error ? e.message : e);
      await new Promise((r) => setTimeout(r, 3000));
      continue;
    }
    for (const update of updates) {
      offset = update.update_id + 1;
      try {
        await handleUpdate(update, config.allowedUserIds, deps);
      } catch (e) {
        console.error("telegram handleUpdate failed:", e instanceof Error ? e.message : e);
      }
    }
  }
}

/** Start the Telegram bridge if TELEGRAM_BOT_TOKEN is set; otherwise a logged no-op.
 *  Returns an AbortController to stop the poll loop (used by tests / shutdown). */
export function startTelegramBridge(
  config: TelegramConfig | null = readTelegramConfig(),
  deps?: TelegramDeps,
): AbortController | null {
  if (!config) {
    console.log("telegram bridge disabled (set TELEGRAM_BOT_TOKEN to enable)");
    return null;
  }
  if (config.allowedUserIds.size === 0) {
    console.warn(
      "telegram bridge: ALLOWED_USER_IDS is empty — every message will be ignored. " +
        "Set ALLOWED_USER_IDS to your numeric Telegram user id(s).",
    );
  }
  const controller = new AbortController();
  const resolved = deps ?? defaultDeps(config.token);
  console.log(`telegram bridge listening (allowed users: ${[...config.allowedUserIds].join(", ") || "none"})`);
  void pollLoop(config, resolved, controller.signal).catch((e) =>
    console.error("telegram bridge crashed:", e),
  );
  return controller;
}
