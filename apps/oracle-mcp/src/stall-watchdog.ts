// Watchdog for dispatched children that go quiet (juancode-8oa5.5). A child hung
// busy, or one whose initial prompt never became a turn, emits no activity event, so
// no subscription fires and the loop waits forever. This is the one timer that looks:
// a dispatched, running session with an open subscription and no transcript growth
// for STALL_AFTER_MS raises ONE "stalled" notification to that subscription. Nothing
// is retried, nagged or re-dispatched, and a transcript it cannot read stays unknown.
import {
  promptUndelivered,
  parseSessionStates,
  type DispatchSessionState,
} from "./dispatch-status.ts";
import { listSessions } from "./oracle.ts";
import { fetchTranscript } from "./session-reads.ts";
import type { SessionSubscription } from "./session-notifications.ts";

export const STALL_AFTER_MS = 20 * 60_000;
const CHECK_EVERY_MS = 60_000;

export interface StallDeps {
  subscriptions: () => Promise<SessionSubscription[]>;
  sessions: () => Promise<DispatchSessionState[]>;
  /** The newest transcript record's seq, -1 for none; null when it cannot be read. */
  progress: (sessionId: string) => Promise<number | null>;
  raise: (subscriptionId: string, sessionId: string, text: string) => Promise<void>;
  now: () => number;
}

interface Watch {
  sessionId: string;
  seq: number;
  since: number;
  fired: boolean;
}

export class StallWatchdog {
  // shortcut: in memory, so a sidecar restart can raise a still-stalled child once more
  // after another full threshold; persist `fired` if that ever proves noisy.
  private watches = new Map<string, Watch>();
  constructor(
    private deps: StallDeps,
    private stallAfterMs = STALL_AFTER_MS,
  ) {}

  async tick(): Promise<void> {
    const subs = await this.deps.subscriptions();
    if (!subs.length) return void this.watches.clear();
    const sessions = await this.deps.sessions();
    const now = this.deps.now();
    const live = new Set<string>();
    for (const sub of subs) {
      const session =
        sub.targetType === "session"
          ? sessions.find((s) => s.id === sub.targetId)
          : sessions.find(
              (s) =>
                s.id === sub.sourceSessionId ||
                (!sub.sourceSessionId && s.dispatchId === sub.targetId),
            );
      // Only a dispatched child still running and not settled: an idle or asking child
      // already notified its subscriber, unless its prompt never arrived at all. A
      // dispatch watch with no event yet is a child that never started a turn.
      const undelivered = promptUndelivered(session ?? null);
      const unsettled =
        sub.lastState === "busy" || (sub.lastState === null && sub.targetType === "dispatch");
      if (!session?.dispatchId || session.status !== "running" || !(undelivered || unsettled))
        continue;
      const seq = await this.deps.progress(session.id).catch(() => null);
      if (seq === null) continue;
      live.add(sub.id);
      const watch = this.watches.get(sub.id);
      if (!watch || watch.sessionId !== session.id || watch.seq !== seq) {
        this.watches.set(sub.id, { sessionId: session.id, seq, since: now, fired: false });
        continue;
      }
      if (watch.fired || now - watch.since < this.stallAfterMs) continue;
      watch.fired = true;
      const minutes = Math.round((now - watch.since) / 60_000);
      const why = undelivered
        ? `its initial prompt was never delivered (${session.promptDelivery!.state}${
            session.promptDelivery!.reason ? `: ${session.promptDelivery!.reason}` : ""
          })`
        : `it is still ${sub.lastState ?? "starting"}`;
      await this.deps.raise(
        sub.id,
        session.id,
        `Stalled: no transcript progress for ${minutes} min and ${why}. Nothing was retried; look at the session and decide.`,
      );
    }
    for (const id of this.watches.keys()) if (!live.has(id)) this.watches.delete(id);
  }
}

/** Starts the check timer; it never keeps the process alive. */
export function startStallWatchdog(
  subscriptions: StallDeps["subscriptions"],
  raise: StallDeps["raise"],
): () => void {
  const dog = new StallWatchdog({
    subscriptions,
    raise,
    sessions: async () => parseSessionStates(await listSessions()),
    progress: async (id) => (await fetchTranscript(id, 1)).records.at(-1)?.seq ?? -1,
    now: Date.now,
  });
  let running = false;
  const timer = setInterval(() => {
    if (running) return;
    running = true;
    dog
      .tick()
      .catch((e: unknown) => console.warn("stall watchdog:", e))
      .finally(() => (running = false));
  }, CHECK_EVERY_MS);
  timer.unref();
  return () => clearInterval(timer);
}
