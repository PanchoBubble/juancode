import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ActivityDetector } from "./activityDetector.ts";
import type { SessionActivity } from "./protocol.ts";

const SETTLE = 1300; // a touch over the detector's SETTLE_MS

describe("ActivityDetector", () => {
  let events: Array<{ state: SessionActivity; notify: boolean }>;
  let det: ActivityDetector;

  beforeEach(() => {
    vi.useFakeTimers();
    events = [];
    det = new ActivityDetector((state, notify) => events.push({ state, notify }));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("goes busy on the working indicator", () => {
    det.feed("✻ Thinking… (3s · esc to interrupt)");
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  it("settles to idle (and notifies) when the indicator stops", () => {
    det.feed("✻ Working… (esc to interrupt)");
    det.feed("Here is the answer.\n"); // a normal completed turn, no prompt
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("classifies an option menu as waiting_input", () => {
    det.feed("Running… esc to interrupt");
    det.feed("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n");
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
  });

  it("ignores the startup banner and user typing (no indicator)", () => {
    det.feed("Welcome to Claude Code!\n");
    det.feed("> what is 2 + 2"); // user typing echoed back
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
  });

  it("stays busy on streaming output even though the phrase isn't re-emitted", () => {
    det.feed("esc to interrupt"); // phrase appears once at the start of the turn
    vi.advanceTimersByTime(800);
    det.feed("streaming a token…"); // later frames carry no phrase, just output
    vi.advanceTimersByTime(800);
    det.feed("more tokens…");
    vi.advanceTimersByTime(800);
    expect(events).toEqual([{ state: "busy", notify: false }]); // never settled early
  });

  it("returns to idle on reset", () => {
    det.feed("esc to interrupt");
    det.reset();
    expect(events.at(-1)).toEqual({ state: "idle", notify: false });
  });
});
