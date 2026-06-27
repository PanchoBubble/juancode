import type { SessionActivity } from "../protocol.ts";

/**
 * Decides whether an activity transition should actually surface an OS
 * notification, so the firehose of `activity` broadcasts can't turn into a
 * Chrome notification flood.
 *
 * The upstream signal is noisy: the server's activity detector can *flap*
 * busy↔waiting_input for a single parked prompt (every TUI repaint of the
 * "esc to interrupt" footer re-enters busy, then settles back to the same
 * waiting_input with a fresh `notify:true`). Without a gate, each flap is a
 * brand-new Chrome notification for the *same* event — which is exactly the
 * spam this guards against.
 *
 * The gate is a pure decision function (clock injected) so it can be unit
 * tested without a DOM:
 *
 *  - **Per-session same-state dedup** — re-entering a state we just notified
 *    for is dropped for {@link SAME_STATE_COOLDOWN_MS}. This kills detector
 *    flapping (same prompt, repainted) while still letting a genuinely new
 *    turn through once the cooldown lapses.
 *  - **Per-session min interval** — any two notifications for one session are
 *    spaced at least {@link SESSION_MIN_INTERVAL_MS} apart, so even a rapid
 *    waiting_input→idle→… churn can't machine-gun.
 *  - **Global burst coalescing** — if more than {@link GLOBAL_BURST_MAX}
 *    notifications would fire inside {@link GLOBAL_WINDOW_MS} (e.g. many
 *    sessions finishing at once), the overflow collapses into a single
 *    "multiple sessions" summary instead of one-per-session.
 */

/** Don't re-notify the *same* boundary for a session within this window. */
export const SAME_STATE_COOLDOWN_MS = 15_000;
/** Floor between any two notifications for one session. */
export const SESSION_MIN_INTERVAL_MS = 4_000;
/** Sliding window for the global burst limiter. */
export const GLOBAL_WINDOW_MS = 5_000;
/** Notifications allowed in {@link GLOBAL_WINDOW_MS} before we coalesce. */
export const GLOBAL_BURST_MAX = 3;

export type NotifyAction =
  /** Surface a per-session notification (sound + OS notification). */
  | "fire"
  /** Collapse into a single replace-in-place summary notification. */
  | "coalesce"
  /** Suppress entirely (duplicate / throttled). */
  | "drop";

export class NotifyGate {
  private readonly lastBySession = new Map<string, { state: SessionActivity; at: number }>();
  private recentGlobal: number[] = [];

  /** Decide what to do with a notify-worthy transition at time `now` (ms). */
  decide(sessionId: string, state: SessionActivity, now: number): NotifyAction {
    const last = this.lastBySession.get(sessionId);
    if (last) {
      // Same boundary repainting (detector flap) — drop for the cooldown.
      if (last.state === state && now - last.at < SAME_STATE_COOLDOWN_MS) return "drop";
      // Any churn faster than the per-session floor — drop.
      if (now - last.at < SESSION_MIN_INTERVAL_MS) return "drop";
    }

    // This notification is accepted in principle; record it for both limiters.
    this.lastBySession.set(sessionId, { state, at: now });
    this.recentGlobal = this.recentGlobal.filter((t) => now - t < GLOBAL_WINDOW_MS);
    const burst = this.recentGlobal.length >= GLOBAL_BURST_MAX;
    this.recentGlobal.push(now);

    return burst ? "coalesce" : "fire";
  }

  /** Forget a session's dedup state (e.g. the user acknowledged it). */
  clear(sessionId: string): void {
    this.lastBySession.delete(sessionId);
  }
}
