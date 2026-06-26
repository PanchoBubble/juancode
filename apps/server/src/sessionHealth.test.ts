import { describe, expect, it } from "vitest";
import { classify, sweep, DEFAULT_STALE_BUSY_MS } from "./sessionHealth.ts";
import type { SessionHealthInput } from "./sessionHealth.ts";

/** Build an input with healthy-by-default fields, overriding only what a test cares about. */
function input(overrides: Partial<SessionHealthInput> = {}): SessionHealthInput {
  return {
    id: "s1",
    status: "running",
    isLive: true,
    activity: "idle",
    lastOutputMs: 1_000,
    resumable: true,
    ...overrides,
  };
}

describe("sessionHealth.classify", () => {
  it("treats a live idle session as healthy", () => {
    expect(classify(input({ activity: "idle" }), 10_000_000)).toBe("healthy");
  });

  it("treats a live busy session with recent output as healthy", () => {
    // Busy and emitted output just now — a working turn, not a stall.
    expect(classify(input({ activity: "busy", lastOutputMs: 9_999_000 }), 10_000_000)).toBe(
      "healthy",
    );
  });

  it("flags an exited session as dead", () => {
    expect(classify(input({ status: "exited", isLive: false, activity: null }), 10_000_000)).toBe(
      "dead",
    );
  });

  it("flags a running-but-not-live session as dead (onExit never fired)", () => {
    expect(classify(input({ status: "running", isLive: false, activity: null }), 10_000_000)).toBe(
      "dead",
    );
  });

  it("flags a busy session with no output past the budget as stale", () => {
    expect(classify(input({ activity: "busy", lastOutputMs: 0 }), DEFAULT_STALE_BUSY_MS + 1)).toBe(
      "stale",
    );
  });

  it("never flags an idle session as stale, no matter how long", () => {
    // An idle session waiting for the user is normal, not a fault — even after hours.
    expect(classify(input({ activity: "idle", lastOutputMs: 0 }), 24 * 60 * 60 * 1000)).toBe(
      "healthy",
    );
  });

  it("never flags a waiting-input session as stale", () => {
    expect(
      classify(input({ activity: "waiting_input", lastOutputMs: 0 }), DEFAULT_STALE_BUSY_MS + 1),
    ).toBe("healthy");
  });

  it("treats the stale threshold as exactly inclusive", () => {
    const s = input({ activity: "busy", lastOutputMs: 0 });
    expect(classify(s, DEFAULT_STALE_BUSY_MS - 1)).toBe("healthy");
    expect(classify(s, DEFAULT_STALE_BUSY_MS)).toBe("stale");
  });
});

describe("sessionHealth.sweep", () => {
  it("returns only unhealthy sessions, in input order", () => {
    const inputs = [
      input({ id: "healthy", activity: "idle" }),
      input({ id: "dead", status: "exited", isLive: false, activity: null, resumable: false }),
      input({ id: "stale", activity: "busy", lastOutputMs: 0 }),
    ];
    const reports = sweep(inputs, DEFAULT_STALE_BUSY_MS + 1);
    expect(reports.map((r) => r.id)).toEqual(["dead", "stale"]);
    expect(reports.map((r) => r.state)).toEqual(["dead", "stale"]);
    // resumable is carried through for the UI's reactivate affordance.
    expect(reports.find((r) => r.id === "dead")?.resumable).toBe(false);
  });

  it("returns nothing when every session is healthy", () => {
    const inputs = [
      input({ id: "a" }),
      input({ id: "b", activity: "busy", lastOutputMs: 10_000_000 }),
    ];
    expect(sweep(inputs, 10_000_001)).toEqual([]);
  });
});
