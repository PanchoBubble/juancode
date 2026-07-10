import { describe, expect, it, vi } from "vitest";
import type { ScreenFrame } from "./native-events.ts";
import { openScreenStream, type ScreenPatch } from "./screen-stream.ts";

function frame(over: Partial<ScreenFrame> = {}): ScreenFrame {
  return {
    sessionId: "s-1",
    reset: true,
    cols: 10,
    rows: 3,
    cursorX: 0,
    cursorY: 0,
    cursorVisible: true,
    alt: false,
    lines: [],
    ...over,
  };
}

/** A fake native subscription: captures the frame listener so tests can push
 *  frames, and records unsubscribes. Session ids are unique per test — the
 *  module keys its shared views by session id. */
function fakeNative() {
  const listeners = new Map<string, (f: ScreenFrame) => void>();
  const unsubscribed: string[] = [];
  const subscribe = vi.fn((sessionId: string, listener: (f: ScreenFrame) => void) => {
    listeners.set(sessionId, listener);
    return () => {
      unsubscribed.push(sessionId);
      listeners.delete(sessionId);
    };
  });
  return {
    subscribe,
    unsubscribed,
    push: (sessionId: string, f: ScreenFrame) => listeners.get(sessionId)?.(f),
  };
}

describe("openScreenStream", () => {
  it("forwards a snapshot as a full-grid patch, then diffs as diffs", () => {
    const native = fakeNative();
    const patches: ScreenPatch[] = [];
    const release = openScreenStream("t-snap", (p) => patches.push(p), native.subscribe);

    native.push(
      "t-snap",
      frame({
        sessionId: "t-snap",
        lines: [
          { row: 0, segs: [{ text: "one" }] },
          { row: 1, segs: [{ text: "two", st: 1 }] },
        ],
      }),
    );
    expect(patches).toHaveLength(1);
    expect(patches[0]).toEqual({
      reset: true,
      cols: 10,
      rows: 3,
      lines: [
        { row: 0, html: "one" },
        { row: 1, html: '<span style="font-weight:700">two</span>' },
        { row: 2, html: "" },
      ],
    });

    native.push(
      "t-snap",
      frame({ sessionId: "t-snap", reset: false, lines: [{ row: 1, segs: [{ text: "TWO" }] }] }),
    );
    expect(patches).toHaveLength(2);
    expect(patches[1]).toEqual({
      reset: false,
      cols: 10,
      rows: 3,
      lines: [{ row: 1, html: "TWO" }],
    });
    release();
  });

  it("turns a geometry change without the reset flag into a full snapshot", () => {
    const native = fakeNative();
    const patches: ScreenPatch[] = [];
    const release = openScreenStream("t-geom", (p) => patches.push(p), native.subscribe);

    native.push("t-geom", frame({ sessionId: "t-geom", lines: [{ row: 0, segs: [{ text: "x" }] }] }));
    native.push(
      "t-geom",
      frame({ sessionId: "t-geom", reset: false, rows: 2, cols: 5, lines: [{ row: 0, segs: [{ text: "y" }] }] }),
    );
    expect(patches[1]).toEqual({
      reset: true,
      cols: 5,
      rows: 2,
      lines: [
        { row: 0, html: "y" },
        { row: 1, html: "" },
      ],
    });
    release();
  });

  it("shares one native subscription and primes a late joiner with a snapshot", () => {
    const native = fakeNative();
    const first: ScreenPatch[] = [];
    const releaseFirst = openScreenStream("t-share", (p) => first.push(p), native.subscribe);
    native.push("t-share", frame({ sessionId: "t-share", lines: [{ row: 0, segs: [{ text: "hello" }] }] }));

    const late: ScreenPatch[] = [];
    const releaseLate = openScreenStream("t-share", (p) => late.push(p), native.subscribe);
    expect(native.subscribe).toHaveBeenCalledTimes(1);
    expect(late).toHaveLength(1);
    expect(late[0]!.reset).toBe(true);
    expect(late[0]!.lines[0]).toEqual({ row: 0, html: "hello" });

    // Subsequent frames reach both viewers.
    native.push(
      "t-share",
      frame({ sessionId: "t-share", reset: false, lines: [{ row: 1, segs: [{ text: "!" }] }] }),
    );
    expect(first).toHaveLength(2);
    expect(late).toHaveLength(2);
    releaseFirst();
    releaseLate();
  });

  it("does not prime a viewer before any frame has arrived", () => {
    const native = fakeNative();
    const patches: ScreenPatch[] = [];
    const release = openScreenStream("t-empty", (p) => patches.push(p), native.subscribe);
    expect(patches).toHaveLength(0);
    release();
  });

  it("unsubscribes from the native stream only when the last viewer leaves", () => {
    const native = fakeNative();
    const releaseA = openScreenStream("t-refs", () => {}, native.subscribe);
    const releaseB = openScreenStream("t-refs", () => {}, native.subscribe);
    releaseA();
    expect(native.unsubscribed).toEqual([]);
    releaseA(); // double-release is a no-op
    expect(native.unsubscribed).toEqual([]);
    releaseB();
    expect(native.unsubscribed).toEqual(["t-refs"]);

    // A fresh viewer after teardown re-subscribes from scratch.
    const patches: ScreenPatch[] = [];
    const releaseC = openScreenStream("t-refs", (p) => patches.push(p), native.subscribe);
    expect(native.subscribe).toHaveBeenCalledTimes(2);
    expect(patches).toHaveLength(0); // no stale snapshot from the old view
    releaseC();
  });

  it("isolates a throwing viewer from the others", () => {
    const native = fakeNative();
    const patches: ScreenPatch[] = [];
    const releaseBad = openScreenStream(
      "t-throw",
      () => {
        throw new Error("boom");
      },
      native.subscribe,
    );
    const releaseGood = openScreenStream("t-throw", (p) => patches.push(p), native.subscribe);
    native.push("t-throw", frame({ sessionId: "t-throw" }));
    expect(patches).toHaveLength(1);
    releaseBad();
    releaseGood();
  });
});
