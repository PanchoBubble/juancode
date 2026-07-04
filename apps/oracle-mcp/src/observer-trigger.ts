// Observe / unobserve a session from OUTSIDE Telegram (juancode-nez). The shipped
// Telegram control surface (juancode-2l4) lets a Telegram chat subscribe to a
// session's transitions via the /observe slash-command — that caller always has a
// chatId. This module is the trigger for callers that DON'T: the headless Oracle
// chat, the Claude mobile MCP connector, and the phone web console ("keep me posted
// on <session>").
//
// With no chatId of its own, an Oracle/MCP-initiated observe fans the subscription
// out to every Telegram chat that could receive it: every chat with an Oracle
// binding (oracle-telegram-sessions.json) plus the allowlisted user ids (for a
// private 1:1 chat Telegram's chatId == userId, so this lets the very first observe
// work before the bot has ever been messaged). It writes to the SAME
// oracle-telegram-observers.json store as /observe, so subscriptions created here
// notify + route replies through the shipped path in telegram.ts unchanged.

import { listSessions } from "./oracle.ts";
import { parseSessionList, projectName } from "./telegram-format.ts";
import { listTelegramChatIds } from "./telegram-store.ts";
import { observeSession, observerChats, unobserveSession } from "./telegram-observe.ts";

/** Injectable so callers/tests can supply the session list without a live native app.
 *  Defaults to the native REST list used everywhere else. */
export type SessionsFetcher = () => Promise<unknown>;

/** Parse ALLOWED_USER_IDS ("5547517536, 123") → number[]. Mirrors telegram.ts's
 *  parseAllowedUserIds; kept local so the MCP-tool path doesn't import the bridge
 *  module (which imports oracle.ts) and risk an import cycle. */
function allowedChatIds(raw: string | undefined = process.env.ALLOWED_USER_IDS): number[] {
  const ids: number[] = [];
  if (!raw) return ids;
  for (const part of raw.split(/[\s,]+/)) {
    if (!part) continue;
    const n = Number(part);
    if (Number.isInteger(n)) ids.push(n);
  }
  return ids;
}

/** The chats an Oracle/MCP-initiated observe should target: known Oracle-bound
 *  chats ∪ allowlisted ids, deduped, order-stable (known first). */
export async function resolveObserverChatIds(): Promise<number[]> {
  const known = await listTelegramChatIds();
  const seen = new Set<number>();
  const out: number[] = [];
  for (const id of [...known, ...allowedChatIds()]) {
    if (seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

export interface ObserveOutcome {
  sessionId: string;
  /** Session title when it could be resolved from the native list, else null. */
  title: string | null;
  /** Project (cwd basename) when resolvable, else null. */
  project: string | null;
  /** Whether the native app was reachable to confirm the session. */
  reachable: boolean;
  /** Whether the session id matched a known session (only meaningful when reachable). */
  found: boolean;
  /** Chats now subscribed (observe) / that were subscribed (unobserve). */
  chatIds: number[];
  /** Observe: chats subscribed. Unobserve: subscriptions removed. */
  changed: number;
}

interface Lookup {
  reachable: boolean;
  title: string | null;
  project: string | null;
  found: boolean;
}

/** Best-effort session resolution: distinguishes "native app unreachable" from
 *  "session id unknown" so callers can reject a typo but tolerate an offline app. */
async function lookup(sessionId: string, fetchSessions: SessionsFetcher): Promise<Lookup> {
  try {
    const s = parseSessionList(await fetchSessions()).find((x) => x.id === sessionId);
    return {
      reachable: true,
      found: !!s,
      title: s ? s.title : null,
      project: s ? projectName(s.cwd) : null,
    };
  } catch {
    return { reachable: false, found: false, title: null, project: null };
  }
}

/**
 * Subscribe every resolved chat to a session's genuine transitions (needs-input /
 * finished). Idempotent per chat. When the native app is reachable but the id
 * matches nothing, does NOT subscribe (a likely typo) and returns found=false so
 * the caller can surface an error. When the app is unreachable it subscribes
 * anyway (the store write is harmless and the point is remote use).
 */
export async function observeSessionForOracle(
  sessionId: string,
  fetchSessions: SessionsFetcher = listSessions,
): Promise<ObserveOutcome> {
  const { reachable, found, title, project } = await lookup(sessionId, fetchSessions);
  if (reachable && !found) {
    return { sessionId, title, project, reachable, found, chatIds: [], changed: 0 };
  }
  const chatIds = await resolveObserverChatIds();
  for (const chatId of chatIds) await observeSession(chatId, sessionId);
  return { sessionId, title, project, reachable, found, chatIds, changed: chatIds.length };
}

/**
 * Stop notifying about a session: unsubscribe EVERY chat currently observing it
 * (not just the resolved fan-out set), so an Oracle-level "stop watching X" clears
 * subscriptions added via /observe too. Returns the number removed.
 */
export async function unobserveSessionForOracle(
  sessionId: string,
  fetchSessions: SessionsFetcher = listSessions,
): Promise<ObserveOutcome> {
  const chats = await observerChats(sessionId);
  let removed = 0;
  for (const chatId of chats) removed += await unobserveSession(chatId, sessionId);
  const { reachable, found, title, project } = await lookup(sessionId, fetchSessions);
  return { sessionId, title, project, reachable, found, chatIds: chats, changed: removed };
}

/** Human-readable "Title — project" label for a resolved (or unresolved) session. */
export function outcomeLabel(o: ObserveOutcome): string {
  if (o.title && o.project) return `${o.title} — ${o.project}`;
  if (o.title) return o.title;
  return o.sessionId.slice(0, 8);
}
