// Block until a dispatch is worth looking at again, so the session that dispatched it
// waits with one backgrounded request instead of polling /api/dispatches. Every poll an
// agent makes is a model turn re-reading its whole context; this loop runs here, in the
// sidecar, where checking costs nothing.
//
// "Worth looking at" means the dispatched agent stopped: it asked for input, settled
// back to idle after working, its session exited, or the dispatch failed to start.

import type { DispatchStatus } from "./dispatch-status.ts";
import type { SessionActivityEvent } from "./native-events.ts";

export type WaitOutcome = "failed" | "exited" | "waiting_input" | "idle" | "timeout";

export interface WaitResult {
  outcome: WaitOutcome;
  status: DispatchStatus;
}

export interface WaitDeps {
  getStatus: (dispatchId: string) => Promise<DispatchStatus>;
  activity: (sessionId: string) => SessionActivityEvent["state"] | undefined;
  subscribe: (listener: (ev: SessionActivityEvent) => void) => () => void;
  now?: () => number;
  /** How often the durable status is re-read between activity events. */
  recheckMs?: number;
  /** Ends the wait early (the HTTP client went away); it resolves as a timeout. */
  signal?: AbortSignal;
}

/** An idle session this old at the start of a wait has already finished its turn,
 *  rather than not having started it yet. */
export const SETTLED_IDLE_AGE_MS = 60_000;

export async function waitForDispatch(
  dispatchId: string,
  timeoutMs: number,
  deps: WaitDeps,
): Promise<WaitResult> {
  const now = deps.now ?? Date.now;
  const recheckMs = deps.recheckMs ?? 5_000;
  const deadline = now() + timeoutMs;
  let sessionId: string | null = null;
  let sawBusy = false;
  let settled: "idle" | "waiting_input" | null = null;
  let wake: (() => void) | null = null;

  const unsubscribe = deps.subscribe((ev) => {
    if (ev.dispatchId !== dispatchId && ev.sessionId !== sessionId) return;
    if (ev.state === "busy") sawBusy = true;
    else if (ev.state === "waiting_input" || sawBusy) settled = ev.state;
    wake?.();
  });
  const onAbort = () => wake?.();
  deps.signal?.addEventListener("abort", onAbort);

  try {
    for (let first = true; ; first = false) {
      const status = await deps.getStatus(dispatchId);
      if (status.result && !status.result.ok) return { outcome: "failed", status };
      const session = status.session;
      if (session?.status === "exited") return { outcome: "exited", status };
      if (session) sessionId = session.id;
      if (settled) return { outcome: settled, status };
      const state = session ? deps.activity(session.id) : undefined;
      if (state === "waiting_input") return { outcome: "waiting_input", status };
      if (
        first &&
        state === "idle" &&
        session?.createdAt !== undefined &&
        now() - session.createdAt >= SETTLED_IDLE_AGE_MS
      ) {
        return { outcome: "idle", status };
      }
      const remaining = deadline - now();
      if (remaining <= 0 || deps.signal?.aborted) return { outcome: "timeout", status };
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(recheckMs, remaining));
        wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      wake = null;
    }
  } finally {
    unsubscribe();
    deps.signal?.removeEventListener("abort", onAbort);
  }
}
