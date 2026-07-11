// Durable sidecar-side record of every dispatch this process created: the
// original args, the immediate outcome, and — when the dispatch originated from a
// Telegram chat — which chat asked for it. The native app owns the *result* truth
// (dispatch-results.jsonl); this registry owns the *request* side, which only the
// sidecar ever sees (prompt, provider, originating chat). Together they answer
// "what happened to my dispatch" (dispatch-status.ts) and let session lifecycle
// events route back to the chat that dispatched the work (telegram.ts).
//
// Same conventions as telegram-store.ts: a flat JSON array in
// `JUANCODE_ORACLE_DIR`, tolerant of a missing/corrupt file, capped so it can't
// grow without bound.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { oracleDir } from "./oracle.ts";

/** One dispatch as this sidecar created it, plus its immediate outcome. */
export interface DispatchRecord {
  dispatchId: string;
  project: string;
  prompt: string;
  provider: string;
  worktree: boolean;
  /** The Telegram chat the dispatch originated from, or null (MCP/console). */
  telegramChatId: number | null;
  /** The create's immediate outcome: acked live, queued offline, or rejected. */
  outcome: "started" | "queued" | "rejected";
  sessionId: string | null;
  error: string | null;
  at: number;
}

/** Newest-first cap on the registry. */
export const DISPATCH_REGISTRY_CAP = 200;

const registryFile = () => join(oracleDir(), "oracle-dispatches.json");

function isDispatchRecord(v: unknown): v is DispatchRecord {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.dispatchId === "string" &&
    r.dispatchId.length > 0 &&
    typeof r.project === "string" &&
    typeof r.prompt === "string" &&
    typeof r.provider === "string" &&
    typeof r.worktree === "boolean" &&
    (typeof r.telegramChatId === "number" || r.telegramChatId === null) &&
    (r.outcome === "started" || r.outcome === "queued" || r.outcome === "rejected") &&
    (typeof r.sessionId === "string" || r.sessionId === null) &&
    (typeof r.error === "string" || r.error === null) &&
    typeof r.at === "number"
  );
}

async function readRegistry(): Promise<DispatchRecord[]> {
  const raw = await readFile(registryFile(), "utf8").catch(() => "");
  if (!raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isDispatchRecord) : [];
  } catch {
    return [];
  }
}

async function writeRegistry(records: DispatchRecord[]): Promise<void> {
  await mkdir(oracleDir(), { recursive: true });
  await writeFile(registryFile(), JSON.stringify(records, null, 2), "utf8");
}

/** Append one dispatch record, dropping the oldest past the cap. */
export async function recordDispatch(record: DispatchRecord): Promise<void> {
  const all = await readRegistry();
  all.push(record);
  await writeRegistry(all.slice(-DISPATCH_REGISTRY_CAP));
}

/** The record for a dispatch id, or null when this sidecar never saw it. */
export async function getDispatch(dispatchId: string): Promise<DispatchRecord | null> {
  const all = await readRegistry();
  for (let i = all.length - 1; i >= 0; i--) {
    if (all[i]!.dispatchId === dispatchId) return all[i]!;
  }
  return null;
}

/** Recent dispatches, newest first. */
export async function listDispatches(limit = 50): Promise<DispatchRecord[]> {
  const all = await readRegistry();
  return all.slice(-Math.max(1, limit)).reverse();
}

/** The Telegram chat a dispatch originated from, or null. The lifecycle
 *  back-channel: a session event carrying this dispatchId notifies that chat. */
export async function dispatchOriginChat(dispatchId: string): Promise<number | null> {
  return (await getDispatch(dispatchId))?.telegramChatId ?? null;
}
