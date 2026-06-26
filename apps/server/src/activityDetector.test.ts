import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ActivityDetector } from "./activityDetector.ts";
import type { SessionActivity } from "./protocol.ts";

const SETTLE = 300; // a touch over the detector's SETTLE_MS
const WATCHDOG = 8100; // a touch over the detector's WATCHDOG_MS
/** A turn-end frame: clear the screen + home the cursor, tearing down the footer. */
const CLEAR = "\x1b[2J\x1b[H";

describe("ActivityDetector", () => {
  let events: Array<{ state: SessionActivity; notify: boolean }>;
  let det: ActivityDetector;

  beforeEach(() => {
    vi.useFakeTimers();
    events = [];
    det = new ActivityDetector(120, 40, (state, notify) => events.push({ state, notify }));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("goes busy on the working indicator", () => {
    det.feed("✻ Thinking… (3s · esc to interrupt)");
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  // Real claude positions the footer segments with same-line cursor moves; the grid
  // renders those as spatial gaps (not glued, not on separate rows), so it matches.
  it.each([
    "✻ Thinking… (esc\x1b[1;44Hto\x1b[1;48Hinterrupt)",
    "✻ Thinking… (esc\x1b[44Gto interrupt)",
    "✻ Thinking… (esc\x1b[40Gto\x1b[44Ginterrupt)",
  ])("goes busy on the cursor-fragmented indicator %j", (frame) => {
    det.feed(frame);
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  it("settles to idle (and notifies) when the footer is erased", () => {
    det.feed("✻ Working… (esc to interrupt)");
    det.feed(`${CLEAR}Here is the answer.\n`); // footer torn down, plain result
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("classifies an option menu as waiting_input", () => {
    det.feed("Running… esc to interrupt");
    det.feed(`${CLEAR}Do you want to proceed?\n ❯ 1. Yes\n   2. No\n`);
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
  });

  it("ignores the startup banner and user typing (no indicator)", () => {
    det.feed("Welcome to Claude Code!\n");
    det.feed("> what is 2 + 2"); // user typing echoed back
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
  });

  // The headline fix: while the footer is still on screen the session stays busy,
  // even across a long quiet stretch. The old quiet-based detector wrongly idled.
  it("stays busy while the footer is visible", () => {
    det.feed("✻ Working… (esc to interrupt)\n"); // footer on its own line
    vi.advanceTimersByTime(SETTLE);
    det.feed("streaming a token…\n"); // output above the footer
    vi.advanceTimersByTime(SETTLE);
    det.feed("more tokens…\n");
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([{ state: "busy", notify: false }]); // never settled early
    // Once the footer is erased, it settles.
    det.feed(`${CLEAR}Done.\n`);
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "idle", notify: true });
  });

  // Safety net: if the footer lingers but the spinner stops emitting, the watchdog
  // demotes the stuck busy.
  it("demotes a stuck busy via the watchdog", () => {
    det.feed("✻ Working… (esc to interrupt)"); // footer stays, no further output
    vi.advanceTimersByTime(WATCHDOG);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("returns to idle on reset", () => {
    det.feed("esc to interrupt");
    det.reset();
    expect(events.at(-1)).toEqual({ state: "idle", notify: false });
  });
});
