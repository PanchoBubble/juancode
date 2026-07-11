// Tail of the native app's durable dispatch outcomes (juancode-2kz.1). The app
// appends one `OracleDispatchResult` JSON line to `dispatch-results.jsonl` per
// processed dispatch — WS- or mailbox-delivered — so a rejection (bad project
// path, spawn failure) exists somewhere a remote caller can actually see, not just
// as a message typed into the live Oracle pty on the Mac. This module tails that
// file and fans new records out to a listener (the Telegram relay in telegram.ts).

import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** Mirror of the Swift `OracleDispatchResult` line shape (fields it may omit are
 *  normalized to null). */
export interface DispatchResultRecord {
  /** The dispatch's minted id; null for agent-written mailbox lines. */
  dispatchId: string | null;
  project: string;
  ok: boolean;
  sessionId: string | null;
  error: string | null;
  /** ms since epoch. */
  at: number;
}

const resultsFile = () => join(oracleDir(), "dispatch-results.jsonl");

// Dispatch ids this process queued to the mailbox (the app was down). Lets the
// relay confirm "your queued dispatch actually started" without pinging for every
// ordinary success. In-memory only: after a sidecar restart the confirmation is
// simply skipped, while failures are always relayed regardless.
const queuedHere = new Set<string>();

/** Record that `dispatch()` fell back to the mailbox for this id. */
export function markQueuedDispatch(id: string): void {
  queuedHere.add(id);
}

/** True (once) when this process queued the id — consumed so each queued dispatch
 *  is confirmed at most once. */
export function consumeQueuedDispatch(id: string | null | undefined): boolean {
  if (!id || !queuedHere.has(id)) return false;
  queuedHere.delete(id);
  return true;
}

/** Parse one JSONL line into a record; null for malformed/foreign lines. */
export function parseDispatchResultLine(line: string): DispatchResultRecord | null {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.project !== "string" || typeof r.ok !== "boolean" || typeof r.at !== "number") {
    return null;
  }
  return {
    dispatchId: typeof r.dispatchId === "string" ? r.dispatchId : null,
    project: r.project,
    ok: r.ok,
    sessionId: typeof r.sessionId === "string" ? r.sessionId : null,
    error: typeof r.error === "string" ? r.error : null,
    at: r.at,
  };
}

/** All durable dispatch outcomes on disk, oldest first. The lookup side of
 *  dispatch-status: a queued dispatch's real start (or failure) only exists here. */
export async function readDispatchResults(): Promise<DispatchResultRecord[]> {
  const raw = await readFile(resultsFile(), "utf8").catch(() => "");
  const out: DispatchResultRecord[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    const record = parseDispatchResultLine(line);
    if (record) out.push(record);
  }
  return out;
}

/**
 * Poll `dispatch-results.jsonl` and invoke `onResult` for each complete line
 * appended after the watcher started (pre-existing records were handled — or are
 * unactionable — by definition). A trailing partial line is left for the next poll;
 * a shrunken/rotated file resets to its new end. Returns a stop function.
 */
export function startDispatchResultsWatcher(
  onResult: (r: DispatchResultRecord) => void,
  intervalMs = 2000,
): () => void {
  let offset: number | null = null; // primed to EOF on the first poll
  let polling = false;

  const poll = async () => {
    if (polling) return; // a slow read must not stack polls
    polling = true;
    try {
      const size = await stat(resultsFile())
        .then((s) => s.size)
        .catch(() => 0);
      if (offset === null || offset > size) {
        offset = size; // first poll, or the file shrank/rotated
        return;
      }
      if (size === offset) return;
      const buf = await readFile(resultsFile()).catch(() => null);
      if (!buf) return;
      const fresh = buf.subarray(offset, size).toString("utf8");
      const lastNewline = fresh.lastIndexOf("\n");
      if (lastNewline < 0) return; // only a torn line so far
      offset += Buffer.byteLength(fresh.slice(0, lastNewline + 1), "utf8");
      for (const line of fresh.slice(0, lastNewline).split("\n")) {
        if (!line.trim()) continue;
        const record = parseDispatchResultLine(line);
        if (record) onResult(record);
      }
    } finally {
      polling = false;
    }
  };

  void poll(); // prime the offset immediately, not a tick later
  const timer = setInterval(() => void poll(), intervalMs);
  return () => clearInterval(timer);
}
