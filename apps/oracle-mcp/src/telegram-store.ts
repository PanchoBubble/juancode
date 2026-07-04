// Per-Telegram-chat session mapping for the Oracle Telegram bridge (juancode-c6y).
// The bridge routes every Telegram message through the SAME headless Oracle backend
// the browser console uses (`oracleChat` in oracle.ts → `claude -p` + `--resume`).
// Continuity is per Telegram chat: each chat keeps its OWN `claude` session id, kept
// deliberately SEPARATE from the browser thread's id so the two don't cross-talk. We
// persist only the lightweight mapping (telegram chatId → claude sessionId), never the
// transcript — the real conversation context lives in `claude --resume`. Stored as a
// flat JSON array under `JUANCODE_ORACLE_DIR` (same control dir as the chat/push
// stores), tolerant of a missing/corrupt file, and unit-tested in telegram-store.test.ts.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** One Telegram chat's binding to a headless Oracle conversation. `chatId` is the
 *  Telegram chat id; `sessionId` is the `claude` session id used with `--resume`. */
export interface TelegramSession {
  chatId: number;
  sessionId: string;
  updatedAt: number;
}

const sessionsFile = () => join(oracleDir(), "oracle-telegram-sessions.json");

async function ensureDir(): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
}

function isTelegramSession(v: unknown): v is TelegramSession {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.chatId === "number" &&
    typeof r.sessionId === "string" &&
    r.sessionId.length > 0 &&
    typeof r.updatedAt === "number"
  );
}

/** Read the raw store, tolerating a missing/corrupt file (→ []). */
async function readStore(): Promise<TelegramSession[]> {
  const raw = await readFile(sessionsFile(), "utf8").catch(() => "");
  if (!raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isTelegramSession);
  } catch {
    return [];
  }
}

async function writeStore(sessions: TelegramSession[]): Promise<void> {
  await ensureDir();
  await writeFile(sessionsFile(), JSON.stringify(sessions, null, 2), "utf8");
}

/** Every Telegram chat id that has an Oracle binding. This is the fan-out target
 *  for observer subscriptions created OUTSIDE Telegram (the MCP tool / HTTP
 *  endpoint), which carry no chat context of their own — see observer-trigger.ts. */
export async function listTelegramChatIds(): Promise<number[]> {
  return (await readStore()).map((s) => s.chatId);
}

/** The `claude` session id bound to a Telegram chat, or null if none yet (a fresh
 *  conversation — the bridge then starts one and records the id it gets back). */
export async function getTelegramSession(chatId: number): Promise<string | null> {
  const found = (await readStore()).find((s) => s.chatId === chatId);
  return found ? found.sessionId : null;
}

/** Bind (or rebind) a Telegram chat to a `claude` session id, bumping `updatedAt`. */
export async function setTelegramSession(
  chatId: number,
  sessionId: string,
  now = Date.now(),
): Promise<void> {
  if (!sessionId) throw new Error("sessionId is required");
  const sessions = await readStore();
  const existing = sessions.find((s) => s.chatId === chatId);
  if (existing) {
    existing.sessionId = sessionId;
    existing.updatedAt = now;
  } else {
    sessions.push({ chatId, sessionId, updatedAt: now });
  }
  await writeStore(sessions);
}

/** Forget a Telegram chat's binding (the `/new` command), so the next message starts
 *  a fresh Oracle conversation. No-op if the chat had no binding. */
export async function clearTelegramSession(chatId: number): Promise<void> {
  const sessions = await readStore();
  const next = sessions.filter((s) => s.chatId !== chatId);
  if (next.length !== sessions.length) await writeStore(next);
}
