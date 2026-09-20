// Two posts of the same work must not become two agent sessions (juancode-nwrb).
//
// The way it went wrong: `/api/dispatch` answered
// `{"ok":true,"started":false,"queued":true,"sessionId":null}` because the app was
// too loaded to ack the create inside the window. The caller read that as "nothing
// happened" and posted the same prompt again. Both the queued dispatch and the
// re-post eventually started, so a ticket whose whole job was deleting worktrees
// ran twice, concurrently, against one shared .git.
//
// The native ledger already dedupes by `dispatchId` — but a retry mints a *new*
// id, so the ledger never sees the two as the same work. This module supplies the
// two keys that do:
//
//   - a request **fingerprint** (project + provider + worktree + prompt, or a
//     caller-supplied idempotency key): a blind retry of the same POST collapses
//     onto the first dispatch instead of creating a second session.
//   - the **bd ticket id**, read out of the prompt: at most one live session per
//     ticket, whatever the prompt's exact wording was.
//
// Everything here is pure; `dispatch.ts` supplies the registry/session state.

import { createHash } from "node:crypto";
import type { DispatchRecord } from "./dispatch-registry.ts";
import type { DispatchStatus } from "./dispatch-status.ts";

/** A bd id as bd prints it: a project prefix, a short base36 suffix, and the
 *  optional `.n` of a subtask (`juancode-2kz.1`). */
const BD_ID = "[a-z][a-z0-9_]{1,31}-[a-z0-9]{2,8}(?:\\.\\d+)*";

// Only an id the prompt NAMES as a ticket counts. Matching every hyphenated token
// that happens to be bd-shaped would refuse dispatches over words like
// "claude-code", and the guard's whole value is that a refusal means something.
const TICKET_CONTEXTS: RegExp[] = [
  // "bd ticket juancode-nwrb", "ticket juancode-nwrb", "issue juancode-nwrb"
  new RegExp(`\\b(?:bd\\s+)?(?:ticket|issue)\\s+(${BD_ID})\\b`, "gi"),
  // "bd show juancode-nwrb", "bd update juancode-nwrb --status …"
  new RegExp(`\\bbd\\s+(?:show|update|close|start|create)\\s+(${BD_ID})\\b`, "gi"),
  // the header line bd itself prints: "◐ juancode-nwrb [BUG] · …". The leading
  // glyph is spelled out rather than `\S?`, which would happily eat the id's own
  // first letter and report "uancode-nwrb".
  new RegExp(
    `^[^\\S\\n]*[\\u25C9\\u25CB\\u25CF\\u25D0\\u25D1\\u25D2\\u25D3\\u25CA\\u2713\\u2714\\u2717\\u2718\\u2022*+\\-]?[^\\S\\n]*(${BD_ID})[^\\S\\n]+\\[`,
    "gim",
  ),
];

/** Every bd ticket id the prompt names as a ticket, lowercased, in first-seen
 *  order. Empty when the prompt is not ticket-shaped — free-form dispatches are
 *  guarded by their fingerprint alone. */
export function ticketIdsInPrompt(prompt: string): string[] {
  const out = new Set<string>();
  for (const re of TICKET_CONTEXTS) {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(prompt)) !== null) out.add(m[1]!.toLowerCase());
  }
  return [...out];
}

/** The fields a fingerprint is taken over — the whole of what the native app is
 *  asked to do. Two requests agreeing on all four ARE the same dispatch. */
export interface FingerprintInput {
  project: string;
  prompt: string;
  provider?: string;
  worktree?: boolean;
  /** A caller-supplied key. When set it replaces the content hash outright, so a
   *  caller can retry with an edited prompt and still be deduped. */
  idempotencyKey?: string | null;
}

export function requestFingerprint(req: FingerprintInput): string {
  if (req.idempotencyKey) return `key:${req.idempotencyKey}`;
  const digest = createHash("sha256")
    .update(
      [req.project, req.provider ?? "claude", req.worktree ? "1" : "0", req.prompt].join("\u0000"),
    )
    .digest("hex");
  return `req:${digest.slice(0, 32)}`;
}

/** A stored record's fingerprint. Recomputed for records written before the field
 *  existed — the registry keeps every input the hash is taken over. */
export function recordFingerprint(record: DispatchRecord): string {
  return record.fingerprint ?? requestFingerprint(record);
}

/** A stored record's ticket ids: the declared one, else read back out of the
 *  prompt, so the guard also covers dispatches made before `ticket` existed. */
export function recordTickets(record: DispatchRecord): string[] {
  return record.ticket ? [record.ticket.toLowerCase()] : ticketIdsInPrompt(record.prompt);
}

/** How long after a dispatch an identical request is read as a retry rather than
 *  a deliberate second run. */
export const DUPLICATE_WINDOW_MS = 10 * 60_000;

/** How long a queued-but-never-resulted dispatch keeps blocking its ticket. Long,
 *  because the app may be down all night; bounded, so a dispatch the app silently
 *  dropped doesn't block that ticket forever. */
export const QUEUED_PENDING_WINDOW_MS = 24 * 60 * 60_000;

/** A dispatch that is, right now, either running or certain to run. */
export interface LiveDispatch {
  dispatchId: string;
  sessionId: string | null;
  tickets: string[];
  /** "running": the native app shows a live session. "queued": accepted, not
   *  started yet, and no result has landed. */
  state: "running" | "queued";
  project: string;
  at: number;
}

/** The dispatches that currently own a session, or are still going to get one. */
export function liveDispatches(
  statuses: DispatchStatus[],
  now: number,
  queuedWindowMs = QUEUED_PENDING_WINDOW_MS,
): LiveDispatch[] {
  const out: LiveDispatch[] = [];
  for (const status of statuses) {
    const request = status.request;
    if (!request) continue;
    const running = status.session?.status === "running";
    const pending =
      request.outcome === "queued" && !status.result && now - request.at <= queuedWindowMs;
    if (!running && !pending) continue;
    out.push({
      dispatchId: status.dispatchId,
      sessionId: status.session?.id ?? status.result?.sessionId ?? request.sessionId,
      tickets: recordTickets(request),
      state: running ? "running" : "queued",
      project: request.project,
      at: request.at,
    });
  }
  return out;
}

/** The earlier dispatch this request is a retry of, or null. Only a dispatch that
 *  started or was queued counts — a rejected one left nothing behind to collide
 *  with, and re-posting it is the right move. */
export function findDuplicate(
  statuses: DispatchStatus[],
  fingerprint: string,
  now: number,
  windowMs = DUPLICATE_WINDOW_MS,
): DispatchRecord | null {
  let best: DispatchRecord | null = null;
  for (const status of statuses) {
    const request = status.request;
    if (!request) continue;
    if (request.outcome === "rejected") continue;
    if (now - request.at > windowMs) continue;
    if (recordFingerprint(request) !== fingerprint) continue;
    if (!best || request.at > best.at) best = request;
  }
  return best;
}

/** The live dispatch already working one of `tickets`, or null. */
export function findTicketConflict(live: LiveDispatch[], tickets: string[]): LiveDispatch | null {
  if (tickets.length === 0) return null;
  const wanted = new Set(tickets.map((t) => t.toLowerCase()));
  for (const candidate of live) {
    if (candidate.tickets.some((t) => wanted.has(t))) return candidate;
  }
  return null;
}
