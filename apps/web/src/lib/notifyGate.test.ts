import { describe, expect, it } from "vitest";
import {
  GLOBAL_BURST_MAX,
  GLOBAL_WINDOW_MS,
  NotifyGate,
  SAME_STATE_COOLDOWN_MS,
  SESSION_MIN_INTERVAL_MS,
} from "./notifyGate.ts";

describe("NotifyGate", () => {
  it("fires the first notification for a session", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
  });

  it("drops a re-entered same state within the cooldown (detector flapping)", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
    // Flap: busy→waiting_input repaints land repeatedly — all suppressed.
    expect(g.decide("s1", "waiting_input", 300)).toBe("drop");
    expect(g.decide("s1", "waiting_input", 1000)).toBe("drop");
    expect(g.decide("s1", "waiting_input", SAME_STATE_COOLDOWN_MS - 1)).toBe("drop");
  });

  it("re-fires the same state once the cooldown lapses (a genuine new turn)", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
    expect(g.decide("s1", "waiting_input", SAME_STATE_COOLDOWN_MS)).toBe("fire");
  });

  it("throttles rapid distinct-state churn by the per-session floor", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
    // Different state but inside the min interval → dropped.
    expect(g.decide("s1", "idle", SESSION_MIN_INTERVAL_MS - 1)).toBe("drop");
    // Past the floor → allowed.
    expect(g.decide("s1", "idle", SESSION_MIN_INTERVAL_MS)).toBe("fire");
  });

  it("tracks sessions independently", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
    expect(g.decide("s2", "waiting_input", 0)).toBe("fire");
    expect(g.decide("s3", "idle", 0)).toBe("fire");
  });

  it("coalesces a global burst across many sessions", () => {
    const g = new NotifyGate();
    // First GLOBAL_BURST_MAX fire individually...
    for (let i = 0; i < GLOBAL_BURST_MAX; i++) {
      expect(g.decide(`s${i}`, "idle", 0)).toBe("fire");
    }
    // ...the overflow within the window collapses into a summary.
    expect(g.decide("sX", "idle", 1)).toBe("coalesce");
    expect(g.decide("sY", "idle", 2)).toBe("coalesce");
  });

  it("resumes individual fires once the global window slides past", () => {
    const g = new NotifyGate();
    for (let i = 0; i < GLOBAL_BURST_MAX; i++) {
      g.decide(`s${i}`, "idle", 0);
    }
    expect(g.decide("sX", "idle", 1)).toBe("coalesce");
    expect(g.decide("sY", "idle", GLOBAL_WINDOW_MS)).toBe("fire");
  });

  it("re-notifies after an explicit acknowledgement clears state", () => {
    const g = new NotifyGate();
    expect(g.decide("s1", "waiting_input", 0)).toBe("fire");
    expect(g.decide("s1", "waiting_input", 500)).toBe("drop");
    g.clear("s1");
    expect(g.decide("s1", "waiting_input", 600)).toBe("fire");
  });
});
