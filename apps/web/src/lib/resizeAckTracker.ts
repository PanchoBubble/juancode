import type { ClientMessage, ServerMessage } from "../protocol.ts";

type ResizeMessage = Extract<ClientMessage, { type: "resize" }>;
type ResizeAck = Extract<ServerMessage, { type: "resizeAck" }>;

/** A re-send instruction the socket should honour after `delayMs`. */
export interface ResizeResend {
  data: string;
  delayMs: number;
}

/** Bounded retries for a resize the pty keeps not-applying (a truly dead session
 * would otherwise be hammered forever). A starting/attaching pty lands well
 * within this; after the cap we give up and let `exit` surface the death. */
const MAX_RETRIES = 5;
const RETRY_DELAY_MS = 150;

/**
 * Tracks the latest desired terminal grid per session so a dropped `resize`
 * can't strand the CLI at the wrong size (juancode-uz6).
 *
 * Unlike keystrokes (every one matters, buffered in order — see
 * {@link InputAckBuffer}), only the *newest* grid per session matters: an older
 * pending size is obsolete the moment a newer one is measured. So this keeps one
 * desired entry per session, each tagged with a monotonic `seq`.
 *
 * The server replies with a `resizeAck` reporting whether the grid reached a live
 * pty. Two failure modes are recovered:
 *   - `applied: false` (or an acked grid != the latest desired): the resize was
 *     dropped — most often because it raced session spawn — so re-assert the
 *     latest grid after a short delay, bounded by {@link MAX_RETRIES}.
 *   - reconnect: the socket re-asserts every tracked grid via {@link pending} so a
 *     reattached / respawned pty (which may boot at a default 80×24) is corrected.
 *
 * Pure and framework-free so it can be unit-tested without a real WebSocket; the
 * socket owns the transport and the retry timers.
 */
export class ResizeAckTracker {
  private seq = 0;
  private readonly desired = new Map<
    string,
    { cols: number; rows: number; seq: number; retries: number }
  >();

  /** Record a session's newest desired grid and return the frame to transmit. */
  track(msg: ResizeMessage): { seq: number; data: string } {
    const seq = ++this.seq;
    this.desired.set(msg.sessionId, { cols: msg.cols, rows: msg.rows, seq, retries: 0 });
    return { seq, data: this.frame(msg.sessionId, msg.cols, msg.rows, seq) };
  }

  /**
   * Handle a `resizeAck`. Returns a re-send instruction when the ack shows the
   * latest desired grid hasn't landed and retries remain, or null when it is
   * satisfied, stale (a newer resize is already outstanding), or exhausted.
   */
  ack(msg: ResizeAck): ResizeResend | null {
    const d = this.desired.get(msg.sessionId);
    // Stale ack: a newer resize for this session is already in flight, so this
    // ack (for an obsolete grid) tells us nothing about the current desire.
    if (!d || msg.seq !== d.seq) return null;
    if (msg.applied && msg.cols === d.cols && msg.rows === d.rows) return null; // landed
    if (d.retries >= MAX_RETRIES) return null; // give up; `exit` will surface a dead pty
    d.retries += 1;
    d.seq = ++this.seq;
    return { data: this.frame(msg.sessionId, d.cols, d.rows, d.seq), delayMs: RETRY_DELAY_MS };
  }

  /**
   * Frames re-asserting every tracked session's latest desired grid, for replay
   * on reconnect. Resets each retry budget and stamps a fresh `seq` so the ack
   * for the replay matches. Sent immediately (no delay) by the socket.
   */
  pending(): string[] {
    const out: string[] = [];
    for (const [sessionId, d] of this.desired) {
      d.retries = 0;
      d.seq = ++this.seq;
      out.push(this.frame(sessionId, d.cols, d.rows, d.seq));
    }
    return out;
  }

  /** Forget a session's desired grid (e.g. it exited). */
  forget(sessionId: string): void {
    this.desired.delete(sessionId);
  }

  /** Drop all tracking (e.g. the server doesn't support `resizeAck`). */
  clear(): void {
    this.desired.clear();
  }

  private frame(sessionId: string, cols: number, rows: number, seq: number): string {
    return JSON.stringify({ type: "resize", sessionId, cols, rows, seq });
  }
}
