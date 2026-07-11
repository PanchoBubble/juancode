import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import {
  ScreenMirror,
  onSessionEvent,
  onSessionScreen,
  parseScreenFrame,
  startActivityListener,
  stopActivityListener,
  type ScreenFrame,
  type SessionActivityEvent,
} from "./native-events.ts";

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

describe("parseScreenFrame", () => {
  it("parses a full screen frame", () => {
    const parsed = parseScreenFrame({
      type: "screen",
      sessionId: "s-1",
      reset: true,
      cols: 80,
      rows: 24,
      cursorX: 3,
      cursorY: 5,
      cursorVisible: true,
      alt: false,
      lines: [{ row: 0, segs: [{ text: "hi", fg: 2, st: 1 }] }],
    });
    expect(parsed).not.toBeNull();
    expect(parsed?.sessionId).toBe("s-1");
    expect(parsed?.reset).toBe(true);
    expect(parsed?.cols).toBe(80);
    expect(parsed?.lines).toEqual([{ row: 0, segs: [{ text: "hi", fg: 2, st: 1 }] }]);
  });

  it("rejects non-screen and malformed frames", () => {
    expect(parseScreenFrame({ type: "output", sessionId: "s-1", data: "x" })).toBeNull();
    expect(parseScreenFrame({ type: "screen", sessionId: "s-1" })).toBeNull();
    expect(parseScreenFrame({ type: "screen", sessionId: "", cols: 1, rows: 1, lines: [] })).toBeNull();
    expect(
      parseScreenFrame({ type: "screen", sessionId: "s-1", cols: 1, rows: 1, lines: [{ segs: "no" }] }),
    ).toBeNull();
  });
});

describe("ScreenMirror", () => {
  it("applies a snapshot then patches only listed rows", () => {
    const m = new ScreenMirror();
    m.apply(
      frame({
        lines: [
          { row: 0, segs: [{ text: "one" }] },
          { row: 1, segs: [{ text: "two" }] },
          { row: 2, segs: [] },
        ],
      }),
    );
    expect(m.text()).toBe("one\ntwo");
    m.apply(frame({ reset: false, lines: [{ row: 1, segs: [{ text: "TWO", st: 1 }] }] }));
    expect(m.lineText(0)).toBe("one");
    expect(m.lineText(1)).toBe("TWO");
    expect(m.line(1)).toEqual([{ text: "TWO", st: 1 }]);
  });

  it("a reset replaces the whole grid, dropping stale rows", () => {
    const m = new ScreenMirror();
    m.apply(frame({ lines: [{ row: 2, segs: [{ text: "stale" }] }] }));
    m.apply(frame({ lines: [{ row: 0, segs: [{ text: "fresh" }] }] }));
    expect(m.text()).toBe("fresh");
  });

  it("a geometry change resets even without the flag", () => {
    const m = new ScreenMirror();
    m.apply(frame({ lines: [{ row: 0, segs: [{ text: "wide" }] }] }));
    m.apply(frame({ reset: false, rows: 5, cols: 20, lines: [] }));
    expect(m.rows).toBe(5);
    expect(m.text()).toBe("");
  });

  it("ignores out-of-range rows and tracks cursor state", () => {
    const m = new ScreenMirror();
    m.apply(frame({ reset: false, cursorX: 4, cursorY: 2, cursorVisible: false, lines: [{ row: 99, segs: [{ text: "x" }] }] }));
    expect(m.text()).toBe("");
    expect(m.cursorX).toBe(4);
    expect(m.cursorY).toBe(2);
    expect(m.cursorVisible).toBe(false);
  });
});

// The live WS path: the shared native-events socket must (a) keep fanning out
// `activity` unchanged and (b) send `subscribeScreen`/`unsubscribeScreen` and
// route `screen` frames to per-session listeners.
describe("screen stream over the shared native WS", () => {
  let wss: WebSocketServer;
  let server: WsSocket | null = null;
  let received: Record<string, unknown>[];
  const prev = process.env.JUANCODE_API;

  beforeEach(async () => {
    received = [];
    wss = new WebSocketServer({ host: "127.0.0.1", port: 0 });
    wss.on("connection", (sock) => {
      server = sock;
      sock.on("message", (data) => received.push(JSON.parse(data.toString())));
    });
    await new Promise<void>((resolve) => wss.on("listening", () => resolve()));
    process.env.JUANCODE_API = `http://127.0.0.1:${(wss.address() as AddressInfo).port}`;
  });

  afterEach(async () => {
    stopActivityListener();
    await new Promise<void>((resolve) => wss.close(() => resolve()));
    if (prev === undefined) delete process.env.JUANCODE_API;
    else process.env.JUANCODE_API = prev;
  });

  const until = async (cond: () => boolean) => {
    const deadline = Date.now() + 2000;
    while (!cond() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
    expect(cond()).toBe(true);
  };

  it("subscribes, receives frames, and keeps activity fan-out intact", async () => {
    const activity: SessionActivityEvent[] = [];
    const frames: ScreenFrame[] = [];
    onSessionEvent((ev) => activity.push(ev));
    startActivityListener();
    await until(() => server !== null);

    // Prove the client socket is fully open (it can receive) before subscribing.
    server!.send(JSON.stringify({ type: "activity", sessionId: "s-1", state: "busy", notify: false }));
    await until(() => activity.length === 1);

    const unsub = onSessionScreen("s-1", (f) => frames.push(f));
    await until(() => received.some((m) => m.type === "subscribeScreen"));
    expect(received.at(-1)).toEqual({ type: "subscribeScreen", sessionId: "s-1" });

    server!.send(
      JSON.stringify({
        type: "screen",
        sessionId: "s-1",
        reset: true,
        cols: 4,
        rows: 2,
        cursorX: 0,
        cursorY: 0,
        cursorVisible: true,
        alt: false,
        lines: [{ row: 0, segs: [{ text: "ok" }] }],
      }),
    );
    await until(() => frames.length === 1);
    const mirror = new ScreenMirror();
    mirror.apply(frames[0]!);
    expect(mirror.text()).toBe("ok");

    // Frames for other sessions don't reach this listener.
    server!.send(JSON.stringify({ type: "screen", sessionId: "other", reset: true, cols: 1, rows: 1, lines: [] }));
    // Activity keeps flowing alongside the screen stream.
    server!.send(JSON.stringify({ type: "activity", sessionId: "s-1", state: "idle", notify: true }));
    await until(() => activity.length === 2);
    expect(frames.length).toBe(1);
    expect(activity[1]).toEqual({ sessionId: "s-1", state: "idle", notify: true });

    // A settle-edge broadcast carries the change rollup through; a malformed one
    // is dropped rather than thrown.
    server!.send(
      JSON.stringify({
        type: "activity",
        sessionId: "s-1",
        state: "idle",
        notify: true,
        changes: { files: 3, additions: 120, deletions: 44 },
      }),
    );
    server!.send(
      JSON.stringify({ type: "activity", sessionId: "s-1", state: "busy", notify: false, changes: { files: "x" } }),
    );
    await until(() => activity.length === 4);
    expect(activity[2]).toEqual({
      sessionId: "s-1",
      state: "idle",
      notify: true,
      changes: { files: 3, additions: 120, deletions: 44 },
    });
    expect(activity[3]).toEqual({ sessionId: "s-1", state: "busy", notify: false });

    unsub();
    await until(() => received.some((m) => m.type === "unsubscribeScreen"));
  });
});
