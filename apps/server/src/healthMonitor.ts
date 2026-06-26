import { registry } from "./registry.ts";
import { sessionDb } from "./db.ts";
import { sweep, type SessionHealthInput } from "./sessionHealth.ts";
import type { SessionHealthReport } from "./protocol.ts";

/** How often the sweep reconciles the store against the live registry. */
const SWEEP_INTERVAL_MS = 30_000;

type HealthListener = (reports: SessionHealthReport[]) => void;

/**
 * Periodic health-check sweep — pillar 3 of the orchestration loop (juancode-02k).
 *
 * Every {@link SWEEP_INTERVAL_MS} it reconciles the persisted session store
 * against the live pty registry and broadcasts the unhealthy sessions (dead /
 * stale) to subscribers, so each WS connection can surface them and offer
 * reactivation. The sweep is **scoped to sessions seen live during this server
 * run** — on startup every persisted session is already `exited` (see
 * `markOrphansExited`), so without this scope the entire history backlog would
 * be flagged "dead" and flood the panel. We only care about sessions that died
 * or stalled while we were watching them.
 *
 * The brittle classification rules live in the pure `sessionHealth.ts`; this
 * module is just the wiring (input assembly + timer + fan-out).
 */
class HealthMonitor {
  private readonly listeners = new Set<HealthListener>();
  /** Ids of sessions that have been live at some point this server run. */
  private readonly seenLive = new Set<string>();
  private timer: NodeJS.Timeout | null = null;
  private latest: SessionHealthReport[] = [];
  private offCreate: (() => void) | null = null;

  /** Begin watching the registry and sweeping on the interval. Idempotent. */
  start(): void {
    if (this.timer) return;
    for (const s of registry.all()) this.seenLive.add(s.id);
    this.offCreate = registry.onCreate((s) => this.seenLive.add(s.id));
    this.timer = setInterval(() => this.runSweep(), SWEEP_INTERVAL_MS);
    this.timer.unref?.();
  }

  /** Stop the timer and detach the registry watcher (for tests / shutdown). */
  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.offCreate?.();
    this.offCreate = null;
  }

  /** The most recent sweep's reports, so a fresh subscriber gets state at once. */
  current(): SessionHealthReport[] {
    return this.latest;
  }

  /** Subscribe to each sweep's results; the latest snapshot is delivered immediately. */
  onHealth(listener: HealthListener): () => void {
    this.listeners.add(listener);
    listener(this.latest);
    return () => this.listeners.delete(listener);
  }

  /**
   * Build the classifier inputs from the persisted store overlaid with live
   * registry state, run the sweep, cache it, and notify subscribers.
   */
  private runSweep(): void {
    const live = new Map(registry.all().map((s) => [s.id, s]));
    const inputs: SessionHealthInput[] = [];
    for (const meta of sessionDb.list()) {
      // Only sessions we've watched go live this run — keeps the history
      // backlog from flooding the sweep.
      if (!this.seenLive.has(meta.id)) continue;
      const liveSession = live.get(meta.id);
      inputs.push({
        id: meta.id,
        // The live session's in-memory status is fresher than the debounced row.
        status: liveSession ? liveSession.meta.status : meta.status,
        isLive: liveSession !== undefined,
        activity: liveSession ? liveSession.activity : null,
        lastOutputMs: liveSession ? liveSession.meta.updatedAt : meta.updatedAt,
        resumable: meta.cliSessionId !== null,
      });
    }
    this.latest = sweep(inputs, Date.now());
    for (const l of this.listeners) l(this.latest);
  }
}

export const healthMonitor = new HealthMonitor();
