// Durable stores for the Telegram session control surface (juancode-2l4 /
// juancode-zkx). Two small JSON files beside oracle-telegram-sessions.json in
// `JUANCODE_ORACLE_DIR`:
//
// - oracle-telegram-observers.json — which Telegram chats observe which agent
//   sessions (the chat gets pinged on that session's genuine state transitions).
// - oracle-telegram-outbound.json — outbound correlation: every session-scoped
//   message the bot sends (notification / confirmation) is recorded as
//   (chatId, messageId) → sessionId, so a native Telegram *reply* to that message
//   can be routed back into the exact session it came from. Capped so the file
//   can't grow without bound.
//
// Same conventions as telegram-store.ts: flat JSON arrays, tolerant of a
// missing/corrupt file, persist-then-return.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** One chat's subscription to one session's state transitions. */
export interface ObservedSession {
  chatId: number;
  sessionId: string;
  addedAt: number;
}

/** One session-scoped message the bot sent, so a reply to it can find its session. */
export interface OutboundRef {
  chatId: number;
  messageId: number;
  sessionId: string;
  /** Session title at send time — used in confirmations without a re-fetch. */
  title: string;
  at: number;
}

/** Newest-first cap on the outbound correlation log. */
export const OUTBOUND_CAP = 500;

const observersFile = () => join(oracleDir(), "oracle-telegram-observers.json");
const outboundFile = () => join(oracleDir(), "oracle-telegram-outbound.json");

async function readJsonArray<T>(file: string, isValid: (v: unknown) => v is T): Promise<T[]> {
  const raw = await readFile(file, "utf8").catch(() => "");
  if (!raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isValid) : [];
  } catch {
    return [];
  }
}

async function writeJsonArray(file: string, items: unknown[]): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
  await writeFile(file, JSON.stringify(items, null, 2), "utf8");
}

function isObserved(v: unknown): v is ObservedSession {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.chatId === "number" &&
    typeof r.sessionId === "string" &&
    r.sessionId.length > 0 &&
    typeof r.addedAt === "number"
  );
}

function isOutbound(v: unknown): v is OutboundRef {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.chatId === "number" &&
    typeof r.messageId === "number" &&
    typeof r.sessionId === "string" &&
    r.sessionId.length > 0 &&
    typeof r.title === "string" &&
    typeof r.at === "number"
  );
}

/** Session ids a chat observes, oldest subscription first. */
export async function listObserved(chatId: number): Promise<string[]> {
  const all = await readJsonArray(observersFile(), isObserved);
  return all.filter((o) => o.chatId === chatId).map((o) => o.sessionId);
}

/** Subscribe a chat to a session. Idempotent. */
export async function observeSession(
  chatId: number,
  sessionId: string,
  now: number = Date.now(),
): Promise<void> {
  const all = await readJsonArray(observersFile(), isObserved);
  if (all.some((o) => o.chatId === chatId && o.sessionId === sessionId)) return;
  all.push({ chatId, sessionId, addedAt: now });
  await writeJsonArray(observersFile(), all);
}

/** Unsubscribe a chat from one session (or from ALL when sessionId is omitted).
 *  Returns how many subscriptions were removed. */
export async function unobserveSession(chatId: number, sessionId?: string): Promise<number> {
  const all = await readJsonArray(observersFile(), isObserved);
  const keep = all.filter(
    (o) => o.chatId !== chatId || (sessionId !== undefined && o.sessionId !== sessionId),
  );
  const removed = all.length - keep.length;
  if (removed > 0) await writeJsonArray(observersFile(), keep);
  return removed;
}

/** All chats observing a session — the notification fan-out list. */
export async function observerChats(sessionId: string): Promise<number[]> {
  const all = await readJsonArray(observersFile(), isObserved);
  return all.filter((o) => o.sessionId === sessionId).map((o) => o.chatId);
}

/** Record one session-scoped outbound message, dropping the oldest entries past
 *  the cap so the correlation log stays bounded. */
export async function recordOutbound(ref: OutboundRef): Promise<void> {
  const all = await readJsonArray(outboundFile(), isOutbound);
  all.push(ref);
  await writeJsonArray(outboundFile(), all.slice(-OUTBOUND_CAP));
}

/** Resolve a Telegram reply target back to the session the bot message was about. */
export async function lookupOutbound(chatId: number, messageId: number): Promise<OutboundRef | null> {
  const all = await readJsonArray(outboundFile(), isOutbound);
  // Newest wins if the same message id were ever reused (Telegram ids are
  // per-chat monotonic, so this is just belt-and-braces).
  for (let i = all.length - 1; i >= 0; i--) {
    const ref = all[i]!;
    if (ref.chatId === chatId && ref.messageId === messageId) return ref;
  }
  return null;
}
