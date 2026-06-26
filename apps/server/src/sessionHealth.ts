import type { SessionActivity } from "./protocol.ts";
import type { SessionHealthReport, SessionHealthState } from "./protocol.ts";

/**
 * The classifier's verdict for one session. Adds `healthy` to the wire's
 * unhealthy-only {@link SessionHealthState} — healthy sessions are filtered out
 * before anything reaches the wire, so they have no on-wire representation.
 */
export type SessionHealthVerdict = SessionHealthState | "healthy";

/**
 * The pure, dependency-free classifier behind the periodic health-check sweep —
 * pillar 3 of the orchestration loop (juancode-0me / juancode-02k).
 *
 * Per-session `onExit` and live activity detection (see `activityDetector.ts`)
 * already exist; what was missing is a periodic pass that *reconciles* the
 * persisted store against the live registry and flags sessions that died or
 * stalled, so the UI can surface them and offer reactivation. The brittle parts
 * — the reconcile rules and the staleness threshold — live here so they're
 * unit-testable without spinning up a real pty (see `sessionHealth.test.ts`).
 *
 * Re-exported `SessionHealthState` / `SessionHealthReport` from the wire protocol
 * so callers can import the classifier and its result types from one place.
 */
export type { SessionHealthReport, SessionHealthState } from "./protocol.ts";

/**
 * The slice of a session's state the classifier needs, assembled by the monitor
 * from the persisted `SessionMeta` plus the live registry. Kept minimal so the
 * rules stay testable in isolation.
 */
export interface SessionHealthInput {
  id: string;
  status: "running" | "exited";
  /** Whether the live registry currently holds this session (its pty is up). */
  isLive: boolean;
  /** Inferred live activity, null for sessions that aren't live. */
  activity: SessionActivity | null;
  /**
   * Epoch-ms of the session's last output / state change (`meta.updatedAt`,
   * which advances on pty output and on exit).
   */
  lastOutputMs: number;
  /** Whether a prior CLI conversation can be resumed (`cliSessionId != null`). */
  resumable: boolean;
}

/**
 * A `busy` session that hasn't emitted output for this long is treated as a
 * stalled turn. Generous (5 min) so a slow-but-working turn — a long build, a
 * big file edit — isn't flagged; only genuinely wedged ones are.
 */
export const DEFAULT_STALE_BUSY_MS = 5 * 60 * 1000;

/**
 * Classify a single session. Pure; `nowMs` and `staleBusyMs` are injected so
 * tests pin the clock and threshold.
 */
export function classify(
  s: SessionHealthInput,
  nowMs: number,
  staleBusyMs: number = DEFAULT_STALE_BUSY_MS,
): SessionHealthVerdict {
  // Dead: the store says it exited, or it claims to be running but isn't in the
  // live registry (the pty died without `onExit` landing — a desync we'd
  // otherwise never notice).
  if (s.status === "exited" || !s.isLive) return "dead";
  // Stale: a turn that's been `busy` with no output past the budget. Idle /
  // waiting-input sessions are deliberately NOT flagged — that's the normal
  // "waiting for you" state, not a fault.
  if (s.activity === "busy" && nowMs - s.lastOutputMs >= staleBusyMs) return "stale";
  return "healthy";
}

/**
 * Classify a batch and return only the unhealthy sessions (state != `healthy`),
 * in input order. The caller decides which sessions to feed in (e.g. only ones
 * seen live this run) and how to surface the result.
 */
export function sweep(
  inputs: SessionHealthInput[],
  nowMs: number,
  staleBusyMs: number = DEFAULT_STALE_BUSY_MS,
): SessionHealthReport[] {
  const reports: SessionHealthReport[] = [];
  for (const s of inputs) {
    const state = classify(s, nowMs, staleBusyMs);
    if (state === "healthy") continue;
    reports.push({ id: s.id, state, resumable: s.resumable });
  }
  return reports;
}
