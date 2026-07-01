import { describe, expect, it } from "vitest";
import { ResizeAckTracker } from "./resizeAckTracker.ts";

const resize = (sessionId: string, cols: number, rows: number) =>
  ({ type: "resize", sessionId, cols, rows }) as const;

const ack = (sessionId: string, seq: number, cols: number, rows: number, applied: boolean) =>
  ({ type: "resizeAck", sessionId, seq, cols, rows, applied }) as const;

describe("ResizeAckTracker", () => {
  it("assigns a monotonic seq and stamps it into the frame", () => {
    const t = new ResizeAckTracker();
    const a = t.track(resize("s1", 80, 24));
    const b = t.track(resize("s1", 100, 30));
    expect(a.seq).toBe(1);
    expect(b.seq).toBe(2);
    expect(JSON.parse(b.data)).toEqual({
      type: "resize",
      sessionId: "s1",
      cols: 100,
      rows: 30,
      seq: 2,
    });
  });

  it("keeps only the latest desired grid per session (newer supersedes older)", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s1", 120, 40));
    // The reconnect replay re-asserts one frame — the newest — not both.
    const pending = t.pending().map((d) => JSON.parse(d));
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({ cols: 120, rows: 40 });
  });

  it("does not re-send when the ack confirms the latest grid landed", () => {
    const t = new ResizeAckTracker();
    const a = t.track(resize("s1", 80, 24));
    expect(t.ack(ack("s1", a.seq, 80, 24, true))).toBeNull();
  });

  it("re-sends the latest grid when the pty wasn't running (applied:false)", () => {
    const t = new ResizeAckTracker();
    const a = t.track(resize("s1", 80, 24));
    const resend = t.ack(ack("s1", a.seq, 80, 24, false));
    expect(resend).not.toBeNull();
    expect(resend!.delayMs).toBeGreaterThan(0);
    const frame = JSON.parse(resend!.data);
    expect(frame).toMatchObject({ type: "resize", sessionId: "s1", cols: 80, rows: 24 });
    // The retry carries a fresh seq so its own ack matches.
    expect(frame.seq).toBeGreaterThan(a.seq);
  });

  it("ignores a stale ack for a superseded resize", () => {
    const t = new ResizeAckTracker();
    const first = t.track(resize("s1", 80, 24));
    t.track(resize("s1", 120, 40)); // supersedes
    // An ack for the OLD seq must not trigger a re-send — a newer grid is desired.
    expect(t.ack(ack("s1", first.seq, 80, 24, false))).toBeNull();
  });

  it("gives up after a bounded number of retries", () => {
    const t = new ResizeAckTracker();
    let seq = t.track(resize("s1", 80, 24)).seq;
    // Drive negative acks until it stops asking to retry.
    let attempts = 0;
    for (;;) {
      const r = t.ack(ack("s1", seq, 80, 24, false));
      if (!r) break;
      seq = JSON.parse(r.data).seq;
      attempts += 1;
      expect(attempts).toBeLessThan(50); // guard against an infinite loop
    }
    expect(attempts).toBe(5);
  });

  it("resets the retry budget on a fresh track (a new drag re-arms retries)", () => {
    const t = new ResizeAckTracker();
    let seq = t.track(resize("s1", 80, 24)).seq;
    // Exhaust retries.
    for (;;) {
      const r = t.ack(ack("s1", seq, 80, 24, false));
      if (!r) break;
      seq = JSON.parse(r.data).seq;
    }
    // A brand-new desired grid re-arms the retry budget.
    const fresh = t.track(resize("s1", 90, 25));
    expect(t.ack(ack("s1", fresh.seq, 90, 25, false))).not.toBeNull();
  });

  it("forgets a session's grid so it isn't replayed after exit", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s2", 100, 30));
    t.forget("s1");
    const sessions = t.pending().map((d) => JSON.parse(d).sessionId);
    expect(sessions).toEqual(["s2"]);
  });

  it("replays every tracked grid on reconnect with fresh seqs", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s2", 100, 30));
    const frames = t.pending().map((d) => JSON.parse(d));
    expect(frames.map((f) => f.sessionId).sort()).toEqual(["s1", "s2"]);
    // Fresh seqs (> the 2 assigned by track) so replay acks match.
    expect(frames.every((f) => f.seq > 2)).toBe(true);
  });

  it("drops all tracking on clear (server can't ack)", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.clear();
    expect(t.pending()).toEqual([]);
  });
});
