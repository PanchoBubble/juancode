// "What happened to my dispatch?" — the merged answer (juancode-2kz.2). Three
// sources, each owning a different slice of the truth:
//
//   - dispatch-registry.ts (sidecar-written): the original args + originating chat.
//   - dispatch-results.jsonl (native-written, read via dispatch-results.ts): the
//     durable outcome — the real sessionId, or the real error. For a dispatch that
//     was queued offline this is the only place its eventual start exists.
//   - the native /api/sessions list: the session's state right now (running/exited,
//     title), matched by the result's sessionId or by the dispatchId the native app
//     now persists on SessionMeta.
//
// All lookups are lenient: a missing registry entry (older dispatch, another
// process) or an unreachable native app degrade to nulls, never throw.

import { getDispatch, listDispatches, type DispatchRecord } from "./dispatch-registry.ts";
import { readDispatchResults, type DispatchResultRecord } from "./dispatch-results.ts";
import { listSessions } from "./oracle.ts";

/** The slice of a native SessionMeta the status answer carries. */
export interface DispatchSessionState {
  id: string;
  title: string;
  cwd: string;
  provider: string;
  status: string;
  dispatchId: string | null;
  /** Epoch ms; absent when the native app did not report it. */
  createdAt?: number;
  /** How the dispatch prompt fared, as the daemon recorded it on the row. Absent for a
   *  session created without one (or by an older daemon). A running PTY alone says
   *  nothing about whether the agent ever received its task. */
  promptDelivery?: PromptDelivery;
}

export interface PromptDelivery {
  /** "pending" | "submitted" | "refused" | "failed"; "failed" means bytes may already be
   *  on screen, so the prompt must never be re-sent. */
  state: string;
  /** For "submitted": whether the text was seen in the input box before the Enter. */
  verified?: boolean;
  reason?: string;
  at: number;
}

function parsePromptDelivery(raw: unknown): PromptDelivery | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const r = raw as Record<string, unknown>;
  if (typeof r.state !== "string") return undefined;
  return {
    state: r.state,
    ...(typeof r.verified === "boolean" ? { verified: r.verified } : {}),
    ...(typeof r.reason === "string" ? { reason: r.reason } : {}),
    at: typeof r.at === "number" ? r.at : 0,
  };
}

/** The prompt provably never became a turn: the agent will sit idle, not work. */
export function promptUndelivered(session: DispatchSessionState | null): boolean {
  const state = session?.promptDelivery?.state;
  return state === "refused" || state === "failed";
}

export interface DispatchStatus {
  dispatchId: string;
  /** The original dispatch args + origin, when this sidecar recorded them. */
  request: DispatchRecord | null;
  /** The durable native-side outcome, when one has landed. */
  result: DispatchResultRecord | null;
  /** The spawned session's current state, when the native app knows it. */
  session: DispatchSessionState | null;
}

/** Injectable /api/sessions fetch, so tests don't need a live native app. */
export type SessionsFetcher = () => Promise<unknown>;

/** Parse the untyped /api/sessions payload into the fields the status needs. */
export function parseSessionStates(raw: unknown): DispatchSessionState[] {
  if (!Array.isArray(raw)) return [];
  const out: DispatchSessionState[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    if (typeof r.id !== "string" || !r.id) continue;
    out.push({
      id: r.id,
      title: typeof r.title === "string" ? r.title : "",
      cwd: typeof r.cwd === "string" ? r.cwd : "",
      provider: typeof r.provider === "string" ? r.provider : "?",
      status: typeof r.status === "string" ? r.status : "unknown",
      dispatchId: typeof r.dispatchId === "string" ? r.dispatchId : null,
      ...(typeof r.createdAt === "number" ? { createdAt: r.createdAt } : {}),
    });
    const promptDelivery = parsePromptDelivery(r.promptDelivery);
    if (promptDelivery) out[out.length - 1]!.promptDelivery = promptDelivery;
  }
  return out;
}

/** The newest durable result per dispatch id (results are append-only). */
function latestResultsById(results: DispatchResultRecord[]): Map<string, DispatchResultRecord> {
  const byId = new Map<string, DispatchResultRecord>();
  for (const r of results) {
    if (r.dispatchId) byId.set(r.dispatchId, r);
  }
  return byId;
}

/** Best-effort session fetch — an unreachable native app is a normal condition
 *  here (the status should still report the durable record). */
async function fetchSessionStates(fetchSessions: SessionsFetcher): Promise<DispatchSessionState[]> {
  try {
    return parseSessionStates(await fetchSessions());
  } catch {
    return [];
  }
}

function matchSession(
  sessions: DispatchSessionState[],
  dispatchId: string,
  sessionId: string | null,
): DispatchSessionState | null {
  return (
    sessions.find((s) => s.dispatchId === dispatchId) ??
    (sessionId ? (sessions.find((s) => s.id === sessionId) ?? null) : null)
  );
}

/** The merged status for one dispatch id. */
export async function getDispatchStatus(
  dispatchId: string,
  fetchSessions: SessionsFetcher = listSessions,
): Promise<DispatchStatus> {
  const [request, results, sessions] = await Promise.all([
    getDispatch(dispatchId),
    readDispatchResults(),
    fetchSessionStates(fetchSessions),
  ]);
  const result = latestResultsById(results).get(dispatchId) ?? null;
  const sessionId = result?.sessionId ?? request?.sessionId ?? null;
  return { dispatchId, request, result, session: matchSession(sessions, dispatchId, sessionId) };
}

/** Recent dispatches (newest first), each merged with its durable result and the
 *  session's current state. One sessions fetch for the whole list. */
export async function listDispatchStatuses(
  limit = 50,
  fetchSessions: SessionsFetcher = listSessions,
): Promise<DispatchStatus[]> {
  const [requests, results, sessions] = await Promise.all([
    listDispatches(limit),
    readDispatchResults(),
    fetchSessionStates(fetchSessions),
  ]);
  const byId = latestResultsById(results);
  return requests.map((request) => {
    const result = byId.get(request.dispatchId) ?? null;
    const sessionId = result?.sessionId ?? request.sessionId;
    return {
      dispatchId: request.dispatchId,
      request,
      result,
      session: matchSession(sessions, request.dispatchId, sessionId),
    };
  });
}
