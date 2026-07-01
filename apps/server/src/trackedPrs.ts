import { randomUUID } from "node:crypto";
import { getPrActivity as realGetPrActivity } from "./gh.ts";
import { registry } from "./registry.ts";
import { sessionDb } from "./db.ts";
import { messageQueue } from "./messageQueue.ts";
import { recoverCliSessionId } from "./recoverSession.ts";
import {
  autoFixPrompt,
  classifyPrActivity,
  deriveTrackState,
  emptySnapshot,
  trackSeedPrompt,
  type PrTrackSnapshot,
} from "./prTracking.ts";
import type { PrActivity } from "./gh.ts";
import type { PullRequest, TrackedPrInfo, TrackNotification } from "./protocol.ts";

/**
 * Tracked-PR registry + poller for the Node dev server (juancode-yow). Brings the
 * native app's in-process PR tracking (juancode-it5/bt2) to `pnpm dev`: clicking
 * "Track" spawns a dedicated agent session seeded with the PR context + the
 * auto-fix-vs-escalate contract, and a 20s loop diffs each PR's `gh` activity,
 * injecting fix prompts into the driving session for auto-fixable changes and
 * raising needs-decision notifications for the rest.
 *
 * It deliberately reuses the existing dev-server building blocks rather than
 * forking: the real `gh` CLI (`gh.ts#getPrActivity`), the session `registry`, and
 * the per-session `messageQueue` (so an injected fix prompt queues-or-delivers
 * exactly like a user-typed message). The pure classification + prompt logic lives
 * in `prTracking.ts`, a faithful port of the Swift `TrackedPr.swift`.
 *
 * The watch list is in-memory for the dev harness's lifetime (sessions don't
 * survive a dev-server restart the way the native app's do); a single process-wide
 * instance fans out `tracked` snapshots + per-escalation `notification`s to every
 * WS connection, mirroring the `messageQueue` observer pattern.
 */

/** Internal per-PR record: the wire `TrackedPrInfo` plus the diff baseline. */
interface TrackedEntry {
  number: number;
  title: string;
  branch: string;
  url: string;
  cwd: string;
  sessionId: string;
  snapshot: PrTrackSnapshot;
  notifications: TrackNotification[];
  lastPolledAt: number | null;
}

/** A change observers react to: the full list moved, or a single escalation fired. */
export type TrackChange =
  | { kind: "tracked"; tracked: TrackedPrInfo[] }
  | { kind: "notification"; trackedId: string; prNumber: number; notification: TrackNotification };

type ChangeListener = (change: TrackChange) => void;

const POLL_INTERVAL_MS = 20_000;

/** Stable `cwd#number` key (matches the web client's `${cwd}#${number}`). */
function keyOf(cwd: string, number: number): string {
  return `${cwd}#${number}`;
}

/** Injectable dependencies, defaulted to the real ones (overridden in tests). */
export interface TrackedPrDeps {
  getPrActivity: (cwd: string, number: number) => Promise<PrActivity | null>;
  /** Spawn a dedicated tracking session; returns its id, or null on failure. */
  spawnSession: (cwd: string) => string | null;
  /** Whether a session is currently live. */
  sessionLive: (id: string) => boolean;
  /** Seed a fresh session with a prompt (verified delivery). */
  seedSession: (id: string, prompt: string) => void;
  /** Hand a prompt to a session: queue-or-deliver, exactly like a user message. */
  injectPrompt: (id: string, prompt: string) => void;
  /** Best-effort revive of an exited driving session so a fix prompt can land. */
  reactivate: (id: string) => Promise<void>;
}

const defaultDeps: TrackedPrDeps = {
  getPrActivity: realGetPrActivity,
  spawnSession: (cwd) => {
    try {
      // skipPermissions so the autonomous fixer can commit/push without prompting,
      // matching the native engine's `SpawnOptions(skipPermissions: true)`.
      return registry.create("claude", cwd, 120, 32, { skipPermissions: true }).id;
    } catch {
      return null;
    }
  },
  sessionLive: (id) => registry.get(id) !== undefined,
  seedSession: (id, prompt) => registry.get(id)?.autoSubmit(prompt),
  injectPrompt: (id, prompt) => {
    messageQueue.add(id, prompt);
    registry.get(id)?.kickQueue();
  },
  reactivate: async (id) => {
    if (registry.get(id)) return;
    const meta = sessionDb.get(id);
    if (!meta) return;
    if (!meta.cliSessionId) {
      const recovered = await recoverCliSessionId(
        meta.provider,
        meta.cwd,
        meta.createdAt,
        sessionDb.usedCliSessionIds(),
      );
      if (recovered) {
        sessionDb.setCliSessionId(meta.id, recovered);
        meta.cliSessionId = recovered;
      }
    }
    if (!meta.cliSessionId) return;
    const prior = sessionDb.getScrollback(meta.id);
    const seed = prior ? `${prior}\r\n\x1b[2m── session resumed ──\x1b[0m\r\n` : "";
    try {
      registry.resume(meta, 120, 32, seed);
    } catch {
      // Couldn't revive — the poller will surface an offline notification.
    }
  },
};

export class TrackedPrRegistry {
  private readonly tracked = new Map<string, TrackedEntry>();
  private readonly listeners = new Set<ChangeListener>();
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly deps: TrackedPrDeps = defaultDeps) {}

  /** The full watch list, most-recently-polled first (matches native ordering). */
  list(): TrackedPrInfo[] {
    return [...this.tracked.values()]
      .sort((a, b) => (b.lastPolledAt ?? 0) - (a.lastPolledAt ?? 0) || b.number - a.number)
      .map((e) => this.toInfo(e));
  }

  private toInfo(e: TrackedEntry): TrackedPrInfo {
    return {
      id: keyOf(e.cwd, e.number),
      number: e.number,
      title: e.title,
      branch: e.branch,
      url: e.url,
      cwd: e.cwd,
      sessionId: e.sessionId,
      state: deriveTrackState(e.snapshot.checks, e.notifications.length > 0),
      checks: e.snapshot.checks,
      notifications: e.notifications,
      lastPolledAt: e.lastPolledAt,
    };
  }

  /**
   * Watch the registry. The new subscriber is *not* called immediately — the WS
   * layer pushes the current snapshot on subscribe itself. Returns a cancel handle.
   */
  onChange(listener: ChangeListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private broadcastTracked(): void {
    if (this.listeners.size === 0) return;
    const tracked = this.list();
    for (const l of this.listeners) l({ kind: "tracked", tracked });
  }

  private broadcastNotification(trackedId: string, prNumber: number, n: TrackNotification): void {
    for (const l of this.listeners) l({ kind: "notification", trackedId, prNumber, notification: n });
  }

  /**
   * Start tracking a PR: spawn a dedicated session seeded with the PR context +
   * auto-fix-vs-escalate contract, register it, and ensure the poll loop runs.
   * No-op if the PR is already tracked.
   */
  track(pr: PullRequest, cwd: string): void {
    const key = keyOf(cwd, pr.number);
    if (this.tracked.has(key)) return;
    const sessionId = this.deps.spawnSession(cwd);
    if (!sessionId) return;
    const seed = trackSeedPrompt({ number: pr.number, title: pr.title, branch: pr.branch, url: pr.url });
    this.deps.seedSession(sessionId, seed);
    this.tracked.set(key, {
      number: pr.number,
      title: pr.title,
      branch: pr.branch,
      url: pr.url,
      cwd,
      sessionId,
      snapshot: emptySnapshot(),
      notifications: [],
      lastPolledAt: null,
    });
    this.broadcastTracked();
    this.startLoop();
  }

  /** Stop tracking a PR. Leaves its agent session alone; stops the loop when none remain. */
  untrack(id: string): void {
    if (!this.tracked.delete(id)) return;
    this.broadcastTracked();
    if (this.tracked.size === 0) this.stopLoop();
  }

  /** Dismiss a surfaced decision once the user has dealt with it. */
  resolveNotification(trackedId: string, notificationId: string): void {
    const entry = this.tracked.get(trackedId);
    if (!entry) return;
    const before = entry.notifications.length;
    entry.notifications = entry.notifications.filter((n) => n.id !== notificationId);
    if (entry.notifications.length !== before) this.broadcastTracked();
  }

  private startLoop(): void {
    if (this.pollTimer) return;
    this.pollTimer = setInterval(() => void this.pollOnce(), POLL_INTERVAL_MS);
    // The setInterval handle shouldn't keep the dev server alive on its own.
    this.pollTimer.unref?.();
  }

  private stopLoop(): void {
    if (!this.pollTimer) return;
    clearInterval(this.pollTimer);
    this.pollTimer = null;
  }

  /**
   * One pass over every tracked PR: fetch its `gh` activity, classify what changed,
   * inject auto-fix prompts into the driving session, and raise notifications for
   * changes that need a human decision. Exposed for testing.
   */
  async pollOnce(): Promise<void> {
    // Snapshot keys so untracking mid-poll (off-loop) can't break iteration.
    for (const key of [...this.tracked.keys()]) {
      const start = this.tracked.get(key);
      if (!start) continue;
      const activity = await this.deps.getPrActivity(start.cwd, start.number);
      if (!activity) continue;
      const entry = this.tracked.get(key); // re-read: may have been untracked while awaiting
      if (!entry) continue;

      const result = classifyPrActivity(entry.snapshot, activity);
      entry.snapshot = result.snapshot;
      entry.lastPolledAt = Date.now();

      // Terminal: the PR merged/closed. Ping observers once (so the client can toast /
      // notify), then drop it from the watch list. Its agent session is left alone.
      const closed = result.events.find((e) => e.kind === "closed");
      if (closed) {
        this.broadcastNotification(key, entry.number, {
          id: randomUUID(),
          prNumber: entry.number,
          message: closed.reason,
          createdAt: Date.now(),
        });
        this.untrack(key);
        continue;
      }

      const fixReasons: string[] = [];
      const newNotifications: TrackNotification[] = [];
      for (const event of result.events) {
        if (event.kind === "autoFix") fixReasons.push(event.reason);
        else
          newNotifications.push({
            id: randomUUID(),
            prNumber: entry.number,
            message: event.reason,
            createdAt: Date.now(),
          });
      }
      entry.notifications.push(...newNotifications);

      if (fixReasons.length > 0) {
        const prompt = autoFixPrompt({ number: entry.number, branch: entry.branch, reasons: fixReasons });
        if (this.deps.sessionLive(entry.sessionId)) {
          this.deps.injectPrompt(entry.sessionId, prompt);
        } else {
          // The driving session is offline (typically after a restart). Revive it
          // lazily, then hand it the fix; if it still can't come back, escalate.
          await this.deps.reactivate(entry.sessionId);
          if (this.deps.sessionLive(entry.sessionId)) {
            this.deps.injectPrompt(entry.sessionId, prompt);
          } else {
            const offlineMsg = "Auto-fix needed, but the driving session is offline and couldn't be resumed.";
            if (!entry.notifications.some((n) => n.message === offlineMsg)) {
              const n: TrackNotification = {
                id: randomUUID(),
                prNumber: entry.number,
                message: offlineMsg,
                createdAt: Date.now(),
              };
              entry.notifications.push(n);
              newNotifications.push(n);
            }
          }
        }
      }

      for (const n of newNotifications) this.broadcastNotification(key, entry.number, n);
    }
    this.broadcastTracked();
  }

  /** Tear everything down (test cleanup / server shutdown). */
  dispose(): void {
    this.stopLoop();
    this.tracked.clear();
    this.listeners.clear();
  }
}

export const trackedPrs = new TrackedPrRegistry();
