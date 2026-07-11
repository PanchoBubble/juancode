// Telegram bridge for the Oracle chat (juancode-c6y) and session control surface
// (juancode-2l4 / juancode-zkx). Plain messages route through the EXACT SAME
// backend as the browser console: `oracleChat` (oracle.ts → headless `claude -p`
// with `--resume`). On top of that the bridge is a first-class phone control
// surface for agent sessions:
//
// - /sessions, /status list live sessions (title, project, live state) with
//   inline observe/unobserve buttons; /observe and /unobserve take a number from
//   the last printed list or an id prefix.
// - Observed sessions ping this chat on genuine state transitions (needs input /
//   finished a turn), reusing the native server's de-spammed `notify` flag via
//   the native-events module's single WS listener (native-events.ts onSessionEvent).
// - Replying (Telegram-native reply) to any session-scoped bot message routes the
//   text into that exact session: typed straight into the pty when it's waiting
//   or idle (deliverReply), queued for the next idle when it's busy
//   (queueMessages). Delivery is confirmed, and the confirmation itself is
//   reply-able so the thread stays connected to the session.
//
// The chat↔session mappings are durable: oracle-telegram-sessions.json (Oracle
// chat continuity), oracle-telegram-observers.json (observe subscriptions), and
// oracle-telegram-outbound.json (bot-message → session correlation) all live in
// `JUANCODE_ORACLE_DIR` and survive restarts.
//
// Transport is long-poll `getUpdates` (no webhook), so it works behind the
// existing cloudflared `oracle` tunnel without exposing an inbound port. On
// startup, if TELEGRAM_BOT_TOKEN is unset the bridge is a no-op; ALLOWED_USER_IDS
// is the allowlist of Telegram user ids permitted to talk to it (anyone else is
// ignored). Replies are chunked to Telegram's 4096-char per-message limit.

import { clearTelegramSession, getTelegramSession, setTelegramSession } from "./telegram-store.ts";
import {
  listObserved,
  lookupOutbound,
  observeSession,
  observerChats,
  recordOutbound,
  unobserveSession,
} from "./telegram-observe.ts";
import {
  classifyActivity,
  dispatchResultText,
  formatSessionLine,
  notifyIcon,
  notifyText,
  orderSessions,
  parseSessionList,
  projectName,
  resolveSelector,
  type LiveActivity,
  type SessionSummary,
} from "./telegram-format.ts";
import {
  consumeQueuedDispatch,
  startDispatchResultsWatcher,
  type DispatchResultRecord,
} from "./dispatch-results.ts";
import { resolveObserverChatIds } from "./observer-trigger.ts";
import { deliverReply, listSessions, oracleChat, queueMessages, type ChatReply } from "./oracle.ts";
import { onSessionEvent, type SessionActivityEvent } from "./native-events.ts";
import { makeTranscriber } from "./transcribe.ts";

/** Telegram's hard per-message character cap. We chunk below it to stay safe. */
const TELEGRAM_MAX_CHARS = 4096;
const CHUNK_LIMIT = 4000;

/** Cap on sessions shown by /sessions, so the message + keyboard stay readable. */
const LIST_CAP = 15;

/** Longest voice/audio note we'll transcribe (juancode-lr5). A cap keeps a stray
 *  hour-long file from wedging whisper for minutes; anything longer gets a friendly
 *  "too long" reply. */
const MAX_AUDIO_SECONDS = 600;

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
/** A Telegram `voice` (OGG/Opus note) or `audio` (music/file) attachment — only the
 *  fields the bridge needs to download and size-check it (juancode-lr5). */
interface TgAudio {
  file_id?: string;
  mime_type?: string;
  duration?: number;
}
interface TgMessage {
  message_id?: number;
  chat?: TgChat;
  from?: TgUser;
  text?: string;
  reply_to_message?: { message_id?: number };
  voice?: TgAudio;
  audio?: TgAudio;
}
interface TgCallbackQuery {
  id?: string;
  from?: TgUser;
  message?: { message_id?: number; chat?: TgChat };
  data?: string;
}
export interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  callback_query?: TgCallbackQuery;
}

/** Pull the well-formed `(chatId, userId, text)` out of an update, or null if it's
 *  not a text message we can act on (edits, photos, joins, etc. are ignored).
 *  `replyTo` is the id of the bot message the user replied to, when it's a
 *  Telegram-native reply. */
export function parseTextMessage(update: TgUpdate): {
  chatId: number;
  userId: number;
  messageId: number | null;
  replyTo: number | null;
  text: string;
} | null {
  const msg = update.message;
  const chatId = msg?.chat?.id;
  const userId = msg?.from?.id;
  const text = msg?.text;
  if (typeof chatId !== "number" || typeof userId !== "number") return null;
  if (typeof text !== "string" || !text.trim()) return null;
  const messageId = typeof msg?.message_id === "number" ? msg.message_id : null;
  const replyTo =
    typeof msg?.reply_to_message?.message_id === "number" ? msg.reply_to_message.message_id : null;
  return { chatId, userId, messageId, replyTo, text: text.trim() };
}

/** Pull a well-formed voice/audio note out of an update, or null if the message has
 *  no transcribable attachment (juancode-lr5). A `voice` note is preferred over an
 *  `audio` file when both are somehow present. */
export function parseVoiceMessage(update: TgUpdate): {
  chatId: number;
  userId: number;
  messageId: number | null;
  fileId: string;
  durationSec: number | null;
} | null {
  const msg = update.message;
  const chatId = msg?.chat?.id;
  const userId = msg?.from?.id;
  if (typeof chatId !== "number" || typeof userId !== "number") return null;
  const media = msg?.voice ?? msg?.audio;
  if (!media || typeof media.file_id !== "string" || !media.file_id) return null;
  const messageId = typeof msg?.message_id === "number" ? msg.message_id : null;
  const durationSec = typeof media.duration === "number" ? media.duration : null;
  return { chatId, userId, messageId, fileId: media.file_id, durationSec };
}

/** Pull a well-formed inline-keyboard press out of an update, or null. */
export function parseCallbackQuery(update: TgUpdate): {
  callbackId: string;
  chatId: number;
  userId: number;
  data: string;
} | null {
  const cb = update.callback_query;
  if (!cb) return null;
  const callbackId = cb.id;
  const userId = cb.from?.id;
  const chatId = cb.message?.chat?.id;
  const data = cb.data;
  if (typeof callbackId !== "string" || !callbackId) return null;
  if (typeof userId !== "number" || typeof chatId !== "number") return null;
  if (typeof data !== "string" || !data) return null;
  return { callbackId, chatId, userId, data };
}

// ── Bridge state + dependency injection ──────────────────────────────────────

/** One inline-keyboard button: `data` becomes the callback_data. */
export interface InlineButton {
  text: string;
  data: string;
}

export interface SendOptions {
  keyboard?: InlineButton[][];
}

/** Per-process (non-durable) bridge state: the numbered list each chat last saw
 *  (so "/observe 2" resolves), the last-known live activity per session (warmed
 *  by the connect-time snapshot the native WS sends), and the last notification
 *  kind per chat+session (a second de-dup layer over the server's gate). */
export interface BridgeState {
  lastList: Map<number, string[]>;
  activity: Map<string, LiveActivity>;
  lastNotified: Map<string, string>;
}

export function newBridgeState(): BridgeState {
  return { lastList: new Map(), activity: new Map(), lastNotified: new Map() };
}

/** The side-effecting collaborators the update handler needs. Injected so the handler
 *  is unit-testable without a real Telegram API or `claude` process. */
export interface TelegramDeps {
  chat: (text: string, sessionId: string | null) => Promise<ChatReply>;
  getSession: (chatId: number) => Promise<string | null>;
  setSession: (chatId: number, sessionId: string) => Promise<void>;
  clearSession: (chatId: number) => Promise<void>;
  /** Send a message; resolves to the sent message's id (null when unknown). */
  send: (chatId: number, text: string, opts?: SendOptions) => Promise<number | null>;
  /** Best-effort "typing…" chat action; never throws (a failed hint must not stall a reply). */
  typing: (chatId: number) => Promise<void>;
  /** Best-effort message reaction. `emoji === null` removes the reaction. Never throws. */
  react: (chatId: number, messageId: number, emoji: string | null) => Promise<void>;
  /** Best-effort answer to an inline-keyboard press (clears the client spinner). */
  answerCallback: (callbackId: string, text?: string) => Promise<void>;
  /** The native server's session list, already parsed into summaries. */
  sessions: () => Promise<SessionSummary[]>;
  observers: {
    list: (chatId: number) => Promise<string[]>;
    add: (chatId: number, sessionId: string) => Promise<void>;
    remove: (chatId: number, sessionId?: string) => Promise<number>;
    chatsFor: (sessionId: string) => Promise<number[]>;
  };
  outbound: {
    record: (ref: {
      chatId: number;
      messageId: number;
      sessionId: string;
      title: string;
      at: number;
    }) => Promise<void>;
    lookup: (
      chatId: number,
      messageId: number,
    ) => Promise<{ sessionId: string; title: string } | null>;
  };
  /** Type text straight into a session's pty (waiting/idle sessions). */
  deliver: (sessionId: string, text: string) => Promise<void>;
  /** Queue text for in-order delivery on the session's next idle (busy sessions). */
  queue: (sessionId: string, texts: string[]) => Promise<void>;
  /** Transcribe a Telegram voice/audio file to text (local whisper CLI). Throws on
   *  download or transcription failure so the handler can reply with a clear error. */
  transcribe: (fileId: string) => Promise<string>;
}

/** The real collaborators, wired to the shared Oracle backend + durable stores. */
function defaultDeps(token: string): TelegramDeps {
  return {
    chat: (text, sessionId) => oracleChat(text, sessionId),
    getSession: getTelegramSession,
    setSession: setTelegramSession,
    clearSession: clearTelegramSession,
    send: (chatId, text, opts) => sendMessage(token, chatId, text, opts),
    typing: (chatId) => sendChatAction(token, chatId, "typing"),
    react: (chatId, messageId, emoji) => setMessageReaction(token, chatId, messageId, emoji),
    answerCallback: (callbackId, text) => answerCallbackQuery(token, callbackId, text),
    sessions: async () => parseSessionList(await listSessions()),
    observers: {
      list: listObserved,
      add: observeSession,
      remove: unobserveSession,
      chatsFor: observerChats,
    },
    outbound: { record: recordOutbound, lookup: lookupOutbound },
    deliver: deliverReply,
    queue: queueMessages,
    transcribe: makeTranscriber(token),
  };
}

const HELP_TEXT = [
  "Oracle bot commands:",
  "/sessions — list agent sessions (live state, observe buttons)",
  "/status — your observed sessions right now",
  "/observe <n|id> — get pinged when a session needs input or finishes",
  "/unobserve [n|id] — stop observing one (or all) sessions",
  "/new — start a fresh Oracle thread",
  "",
  "Anything else goes to the Oracle. Send a voice note and it's transcribed",
  "(locally) and sent to the Oracle. Reply to a session notification to send",
  "your answer into that exact session.",
].join("\n");

/** Handle one update: enforce the allowlist, route commands and session replies,
 *  and send everything else through the shared Oracle backend, persisting the
 *  returned session id so the chat stays continuous. Non-allowed users are ignored
 *  (logged, no reply) so the private bot doesn't announce itself to strangers. */
export async function handleUpdate(
  update: TgUpdate,
  allowed: Set<number>,
  deps: TelegramDeps,
  state: BridgeState = newBridgeState(),
): Promise<void> {
  const callback = parseCallbackQuery(update);
  if (callback) {
    if (!isAllowed(callback.userId, allowed)) {
      console.warn(`telegram: ignoring callback from non-allowed user ${callback.userId}`);
      await deps.answerCallback(callback.callbackId);
      return;
    }
    await handleCallback(callback, deps, state);
    return;
  }

  // A voice note or audio file is transcribed locally, then treated exactly like a
  // typed message to the Oracle (juancode-lr5).
  const voice = parseVoiceMessage(update);
  if (voice) {
    if (!isAllowed(voice.userId, allowed)) {
      console.warn(`telegram: ignoring voice note from non-allowed user ${voice.userId}`);
      return;
    }
    await handleVoiceMessage(voice, deps);
    return;
  }

  const parsed = parseTextMessage(update);
  if (!parsed) return;
  const { chatId, userId, messageId, replyTo, text } = parsed;

  if (!isAllowed(userId, allowed)) {
    console.warn(`telegram: ignoring message from non-allowed user ${userId}`);
    return;
  }

  // A Telegram-native reply to one of our session-scoped messages routes into that
  // session — never into the Oracle chat (replying is an explicit targeting act).
  if (replyTo !== null) {
    const handled = await handleSessionReply(chatId, messageId, replyTo, text, deps, state);
    if (handled) return;
  }

  const command = text.toLowerCase();
  if (command === "/new" || command === "/start") {
    await deps.clearSession(chatId);
    await deps.send(
      chatId,
      command === "/start"
        ? "👋 Oracle here. Send a message to start, /sessions to drive agents. /help lists commands."
        : "🆕 Started a fresh Oracle thread.",
    );
    return;
  }
  if (command === "/help") {
    await deps.send(chatId, HELP_TEXT);
    return;
  }
  if (command === "/sessions") {
    await handleSessionsCommand(chatId, deps, state);
    return;
  }
  if (command === "/status") {
    await handleStatusCommand(chatId, deps, state);
    return;
  }
  if (command === "/observe" || command.startsWith("/observe ")) {
    await handleObserveCommand(chatId, text.slice("/observe".length).trim(), deps, state);
    return;
  }
  if (command === "/unobserve" || command.startsWith("/unobserve ")) {
    await handleUnobserveCommand(chatId, text.slice("/unobserve".length).trim(), deps, state);
    return;
  }

  await runOracleTurn(chatId, messageId, text, deps);
}

/** The shared "one message to the Oracle" turn: working indicator, backend call,
 *  session persistence, chunked reply. Used by both typed text and transcribed voice
 *  notes so the two stay in lockstep. `messageId` is the user's message to react on
 *  (null ⇒ no reaction). */
async function runOracleTurn(
  chatId: number,
  messageId: number | null,
  text: string,
  deps: TelegramDeps,
): Promise<void> {
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

/** Transcribe a voice/audio note locally and feed the transcript to the Oracle as if
 *  it had been typed (juancode-lr5). The 👀/typing indicator covers the (slow) download
 *  + whisper step. The transcript is echoed back (🎙️) so a mistranscription is visible
 *  before Oracle acts on it. Over-long notes, transcription failures, and empty speech
 *  each end the turn with a clear reply; the session is left untouched so the user can
 *  simply try again. */
async function handleVoiceMessage(
  voice: NonNullable<ReturnType<typeof parseVoiceMessage>>,
  deps: TelegramDeps,
): Promise<void> {
  const { chatId, messageId, durationSec } = voice;

  if (durationSec !== null && durationSec > MAX_AUDIO_SECONDS) {
    await deps.send(
      chatId,
      `⚠️ That audio is too long to transcribe (limit ${Math.floor(MAX_AUDIO_SECONDS / 60)} min). ` +
        "Send a shorter note or type it out.",
    );
    return;
  }

  if (messageId !== null) await deps.react(chatId, messageId, "👀");
  await deps.typing(chatId);
  const typingTimer = setInterval(() => void deps.typing(chatId), 4000);

  let transcript: string;
  try {
    transcript = (await deps.transcribe(voice.fileId)).trim();
  } catch (e) {
    console.error("telegram: transcription failed:", e instanceof Error ? e.message : e);
    await deps.send(
      chatId,
      "⚠️ Couldn't transcribe that voice message. Please try again or type it out.",
    );
    return;
  } finally {
    clearInterval(typingTimer);
    if (messageId !== null) await deps.react(chatId, messageId, null);
  }

  if (!transcript) {
    await deps.send(chatId, "⚠️ I couldn't make out any speech in that audio.");
    return;
  }

  // Show what was heard, then feed it to the Oracle exactly as if it had been typed.
  await deps.send(chatId, `🎙️ ${transcript}`);
  await runOracleTurn(chatId, messageId, transcript, deps);
}

// ── Session commands ─────────────────────────────────────────────────────────

/** Fetch + order sessions, tolerating the native app being down with a clear
 *  message to the chat. Returns null after messaging on failure. */
async function fetchOrdered(chatId: number, deps: TelegramDeps): Promise<SessionSummary[] | null> {
  try {
    return orderSessions(await deps.sessions());
  } catch (e) {
    await deps.send(chatId, `⚠️ ${e instanceof Error ? e.message : String(e)}`);
    return null;
  }
}

async function handleSessionsCommand(
  chatId: number,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  const ordered = await fetchOrdered(chatId, deps);
  if (!ordered) return;
  const list = ordered.slice(0, LIST_CAP);
  if (list.length === 0) {
    await deps.send(chatId, "No sessions right now. Ask the Oracle to dispatch one.");
    return;
  }
  const observed = new Set(await deps.observers.list(chatId));
  state.lastList.set(
    chatId,
    list.map((s) => s.id),
  );
  const lines = list.map((s, i) =>
    formatSessionLine(i + 1, s, state.activity.get(s.id), observed.has(s.id)),
  );
  const more = ordered.length > list.length ? `\n…and ${ordered.length - list.length} more` : "";
  const keyboard = buttonRows(
    list.map((s, i) =>
      observed.has(s.id)
        ? { text: `✓${i + 1}`, data: `u:${s.id}` }
        : { text: `👁${i + 1}`, data: `o:${s.id}` },
    ),
  );
  await deps.send(chatId, lines.join("\n") + more, { keyboard });
}

async function handleStatusCommand(
  chatId: number,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  const observedIds = await deps.observers.list(chatId);
  if (observedIds.length === 0) {
    await deps.send(chatId, "You're not observing any sessions. /sessions to pick some.");
    return;
  }
  const ordered = await fetchOrdered(chatId, deps);
  if (!ordered) return;
  const byId = new Map(ordered.map((s) => [s.id, s]));
  state.lastList.set(chatId, observedIds);
  const lines = observedIds.map((id, i) => {
    const s = byId.get(id);
    if (!s) return `${i + 1}. ❔ ${id.slice(0, 8)} (gone — /unobserve ${i + 1})`;
    return formatSessionLine(i + 1, s, state.activity.get(id), false);
  });
  const keyboard = buttonRows(
    observedIds.map((id, i) => ({ text: `🚫${i + 1}`, data: `u:${id}` })),
  );
  await deps.send(chatId, `Observing ${observedIds.length}:\n` + lines.join("\n"), { keyboard });
}

async function handleObserveCommand(
  chatId: number,
  selector: string,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  if (!selector) {
    await deps.send(chatId, "Usage: /observe <n|id> — n from the last /sessions list.");
    return;
  }
  const ordered = await fetchOrdered(chatId, deps);
  if (!ordered) return;
  const id = resolveSelector(selector, ordered, state.lastList.get(chatId));
  if (!id) {
    await deps.send(chatId, `No session matches “${selector}”. /sessions to list them.`);
    return;
  }
  await deps.observers.add(chatId, id);
  const s = ordered.find((x) => x.id === id);
  const name = s ? `${s.title} — ${projectName(s.cwd)}` : id.slice(0, 8);
  await deps.send(
    chatId,
    `👁 Observing ${name}. I'll ping you here when it needs input or finishes.`,
  );
}

async function handleUnobserveCommand(
  chatId: number,
  selector: string,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  if (!selector || selector.toLowerCase() === "all") {
    const removed = await deps.observers.remove(chatId);
    await deps.send(
      chatId,
      removed > 0
        ? `🚫 Stopped observing ${removed} session(s).`
        : "You weren't observing anything.",
    );
    return;
  }
  // Resolve against the durable observed list too, so an exited/gone session can
  // still be unobserved by its /status index or id prefix.
  const observedIds = await deps.observers.list(chatId);
  let id: string | null = null;
  if (/^\d+$/.test(selector)) {
    const last = state.lastList.get(chatId);
    const ids = last && last.length > 0 ? last : observedIds;
    const n = Number(selector);
    id = n >= 1 && n <= ids.length ? ids[n - 1]! : null;
  } else {
    const matches = observedIds.filter((x) => x === selector || x.startsWith(selector));
    id = matches.length === 1 ? matches[0]! : null;
  }
  if (!id) {
    await deps.send(chatId, `No observed session matches “${selector}”. /status to list them.`);
    return;
  }
  const removed = await deps.observers.remove(chatId, id);
  await deps.send(
    chatId,
    removed > 0 ? "🚫 Stopped observing it." : "You weren't observing that one.",
  );
}

/** Chunk one flat button list into keyboard rows of up to 5. */
function buttonRows(buttons: InlineButton[], perRow = 5): InlineButton[][] {
  const rows: InlineButton[][] = [];
  for (let i = 0; i < buttons.length; i += perRow) rows.push(buttons.slice(i, i + perRow));
  return rows;
}

// ── Inline-keyboard presses ──────────────────────────────────────────────────

async function handleCallback(
  cb: { callbackId: string; chatId: number; userId: number; data: string },
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  const sep = cb.data.indexOf(":");
  const op = sep === -1 ? cb.data : cb.data.slice(0, sep);
  const sessionId = sep === -1 ? "" : cb.data.slice(sep + 1);
  if (!sessionId || (op !== "o" && op !== "u")) {
    await deps.answerCallback(cb.callbackId);
    return;
  }
  try {
    if (op === "o") {
      await deps.observers.add(cb.chatId, sessionId);
      await deps.answerCallback(cb.callbackId, "👁 Observing — I'll ping you here.");
    } else {
      const removed = await deps.observers.remove(cb.chatId, sessionId);
      await deps.answerCallback(
        cb.callbackId,
        removed > 0 ? "🚫 Stopped observing." : "Wasn't observing that one.",
      );
    }
    // De-dup memory is per subscription; a fresh observe should notify afresh.
    state.lastNotified.delete(`${cb.chatId}:${sessionId}`);
  } catch (e) {
    await deps.answerCallback(cb.callbackId, `Failed: ${e instanceof Error ? e.message : e}`);
  }
}

// ── Reply-to-notification → session injection ────────────────────────────────

/** Route a Telegram-native reply into the session its target message was about.
 *  Returns false when the replied-to message isn't one of ours (the caller then
 *  treats the text as a normal Oracle message). */
async function handleSessionReply(
  chatId: number,
  messageId: number | null,
  replyTo: number,
  text: string,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<boolean> {
  const ref = await deps.outbound.lookup(chatId, replyTo);
  if (!ref) return false;
  try {
    const busy = state.activity.get(ref.sessionId) === "busy";
    if (busy) await deps.queue(ref.sessionId, [text]);
    else await deps.deliver(ref.sessionId, text);
    if (messageId !== null) await deps.react(chatId, messageId, "👍");
    const confirmation = busy
      ? `📥 Queued for “${ref.title}” — delivers when it next goes idle. Reply here to send more.`
      : `✅ Sent to “${ref.title}”. Reply here to send more.`;
    const mid = await deps.send(chatId, confirmation);
    // The confirmation is itself a session-scoped message: replying to it chains.
    if (mid !== null) {
      await deps.outbound.record({
        chatId,
        messageId: mid,
        sessionId: ref.sessionId,
        title: ref.title,
        at: Date.now(),
      });
    }
  } catch (e) {
    await deps.send(
      chatId,
      `⚠️ Couldn't deliver to “${ref.title}”: ${e instanceof Error ? e.message : String(e)}`,
    );
  }
  return true;
}

// ── Observer notifications ───────────────────────────────────────────────────

/**
 * Fan one native activity event out to the chats observing that session. Fires
 * only on genuine, alert-worthy transitions: the server's notificationGate sets
 * `notify`, and `classifyActivity` keeps just needs-input / finished-turn. A
 * per-chat last-kind memory suppresses byte-identical repeats (e.g. after a WS
 * reconnect replays a state). Every non-notify event still lands in the activity
 * cache so /sessions and /status stay accurate.
 */
export async function notifySessionEvent(
  ev: SessionActivityEvent,
  deps: TelegramDeps,
  state: BridgeState,
): Promise<void> {
  state.activity.set(ev.sessionId, ev.state);
  const kind = classifyActivity(ev.state, ev.notify);
  if (!kind) return;
  const chats = await deps.observers.chatsFor(ev.sessionId);
  if (chats.length === 0) return;

  // One list fetch per event (only when someone is observing) for title + project.
  let title = ev.sessionId.slice(0, 8);
  let project = "";
  try {
    const s = (await deps.sessions()).find((x) => x.id === ev.sessionId);
    if (s) {
      title = s.title;
      project = projectName(s.cwd);
    }
  } catch {
    // Native app unreachable — notify with the id slice rather than staying silent.
  }

  const header = project ? `${title} — ${project}` : title;
  const hint =
    kind === "needs_input"
      ? "↩️ Reply to this message to answer it."
      : "↩️ Reply to this message to send a follow-up.";
  const text = `${notifyIcon(kind)} ${header}\n${notifyText(kind)}\n${hint}`;

  for (const chatId of chats) {
    const key = `${chatId}:${ev.sessionId}`;
    if (state.lastNotified.get(key) === kind) continue;
    state.lastNotified.set(key, kind);
    try {
      const mid = await deps.send(chatId, text);
      if (mid !== null) {
        await deps.outbound.record({
          chatId,
          messageId: mid,
          sessionId: ev.sessionId,
          title,
          at: Date.now(),
        });
      }
    } catch (e) {
      console.warn("telegram notify failed:", e instanceof Error ? e.message : e);
    }
  }
}

// ── Telegram HTTP API ────────────────────────────────────────────────────────

const apiBase = (token: string) => `https://api.telegram.org/bot${token}`;

/** Send a plain-text message (no parse_mode → no Markdown/HTML escaping pitfalls),
 *  optionally with an inline keyboard. Resolves to the sent message id (null when
 *  Telegram's response doesn't carry one). */
async function sendMessage(
  token: string,
  chatId: number,
  text: string,
  opts?: SendOptions,
): Promise<number | null> {
  const body: Record<string, unknown> = { chat_id: chatId, text };
  if (opts?.keyboard && opts.keyboard.length > 0) {
    body.reply_markup = {
      inline_keyboard: opts.keyboard.map((row) =>
        row.map((b) => ({ text: b.text, callback_data: b.data })),
      ),
    };
  }
  const res = await fetch(`${apiBase(token)}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`telegram sendMessage ${res.status}: ${detail.slice(0, 200)}`);
  }
  const data = (await res.json().catch(() => null)) as {
    result?: { message_id?: unknown };
  } | null;
  const mid = data?.result?.message_id;
  return typeof mid === "number" ? mid : null;
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

/** Best-effort acknowledgement of an inline-keyboard press. `text` shows as a small
 *  toast on the phone. Swallows failures — an unacked spinner times out on its own. */
async function answerCallbackQuery(
  token: string,
  callbackId: string,
  text?: string,
): Promise<void> {
  try {
    const res = await fetch(`${apiBase(token)}/answerCallbackQuery`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ callback_query_id: callbackId, ...(text ? { text } : {}) }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      console.warn(`telegram answerCallbackQuery ${res.status}: ${detail.slice(0, 200)}`);
    }
  } catch (e) {
    console.warn("telegram answerCallbackQuery failed:", e instanceof Error ? e.message : e);
  }
}

/** One long-poll `getUpdates` call (timeout=50s server-side), scoped to message +
 *  inline-keyboard updates. Returns the updates array (possibly empty). */
async function getUpdates(token: string, offset: number): Promise<TgUpdate[]> {
  const url = `${apiBase(token)}/getUpdates?timeout=50&offset=${offset}&allowed_updates=${encodeURIComponent(
    '["message","callback_query"]',
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
async function pollLoop(
  config: TelegramConfig,
  deps: TelegramDeps,
  state: BridgeState,
  signal: AbortSignal,
): Promise<void> {
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
        await handleUpdate(update, config.allowedUserIds, deps, state);
      } catch (e) {
        console.error("telegram handleUpdate failed:", e instanceof Error ? e.message : e);
      }
    }
  }
}

/** Start the Telegram bridge if TELEGRAM_BOT_TOKEN is set; otherwise a logged no-op.
 *  Also subscribes to the native-events module's session-event stream so observed
 *  sessions notify their Telegram chats. Returns an AbortController to stop the
 *  poll loop (used by tests / shutdown). `subscribe` is injectable for tests. */
export function startTelegramBridge(
  config: TelegramConfig | null = readTelegramConfig(),
  deps?: TelegramDeps,
  subscribe: (listener: (ev: SessionActivityEvent) => void) => void = onSessionEvent,
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
  const state = newBridgeState();
  subscribe((ev) => {
    void notifySessionEvent(ev, resolved, state).catch((e) =>
      console.error("telegram session notify failed:", e instanceof Error ? e.message : e),
    );
  });
  console.log(
    `telegram bridge listening (allowed users: ${[...config.allowedUserIds].join(", ") || "none"})`,
  );
  void pollLoop(config, resolved, state, controller.signal).catch((e) =>
    console.error("telegram bridge crashed:", e),
  );
  return controller;
}

/**
 * Relay durable dispatch outcomes (dispatch-results.jsonl, written by the native
 * app) to Telegram (juancode-2kz.1): every failure — a dispatch rejected for a bad
 * project path or a failed spawn must reach the remote caller, not just the Oracle
 * pty on the Mac — plus a start-confirmation for dispatches this sidecar queued
 * offline. Fans out to the same chats an MCP-initiated observe would target.
 * No-op (null) without a bot token; returns a stop function otherwise.
 */
export function startDispatchResultRelay(
  config: TelegramConfig | null = readTelegramConfig(),
  subscribe: (
    onResult: (r: DispatchResultRecord) => void,
  ) => () => void = startDispatchResultsWatcher,
  send: (chatId: number, text: string) => Promise<unknown> = (chatId, text) =>
    sendMessage(config!.token, chatId, text),
): (() => void) | null {
  if (!config) return null;
  return subscribe((record) => {
    const text = dispatchResultText(record, consumeQueuedDispatch(record.dispatchId));
    if (!text) return;
    void (async () => {
      for (const chatId of await resolveObserverChatIds()) {
        await send(chatId, text).catch((e) =>
          console.error("telegram dispatch relay failed:", e instanceof Error ? e.message : e),
        );
      }
    })();
  });
}
