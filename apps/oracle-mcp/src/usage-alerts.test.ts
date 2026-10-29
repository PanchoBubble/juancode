import { describe, expect, it } from "vitest";
import {
  DEFAULT_CONTEXT_FRACTION,
  DEFAULT_HANDOFF_TOKENS,
  readUsageAlertThresholds,
  REARM_MARGIN,
  UsageAlertLatch,
} from "./usage-alerts.ts";
import type { SessionUsageSample } from "./native-events.ts";

/** A reading at `fraction` of a 200k window, optionally with a spend figure. */
function sample(fraction: number | undefined, costUsd?: number): SessionUsageSample {
  const s: SessionUsageSample = { sessionId: "s1", totalTokens: 1000 };
  if (fraction !== undefined) {
    s.contextWindow = 200_000;
    s.contextTokens = Math.round(fraction * 200_000);
    s.contextFraction = fraction;
  }
  if (costUsd !== undefined) s.costUsd = costUsd;
  return s;
}

describe("readUsageAlertThresholds", () => {
  it("defaults to an 80% context line and no spend cap", () => {
    const t = readUsageAlertThresholds({});
    expect(t.contextFraction).toBe(DEFAULT_CONTEXT_FRACTION);
    expect(t.spendCapUsd).toBe(0);
  });

  it("reads a percentage for context and dollars for spend", () => {
    const t = readUsageAlertThresholds({
      JUANCODE_CONTEXT_ALERT_PERCENT: "90",
      JUANCODE_SESSION_SPEND_CAP_USD: "12.50",
    });
    expect(t.contextFraction).toBeCloseTo(0.9);
    expect(t.spendCapUsd).toBe(12.5);
  });

  it("treats 0 as off and anything unparseable as the default", () => {
    expect(readUsageAlertThresholds({ JUANCODE_CONTEXT_ALERT_PERCENT: "0" }).contextFraction).toBe(
      0,
    );
    expect(
      readUsageAlertThresholds({ JUANCODE_CONTEXT_ALERT_PERCENT: "nope" }).contextFraction,
    ).toBe(DEFAULT_CONTEXT_FRACTION);
    expect(
      readUsageAlertThresholds({ JUANCODE_CONTEXT_ALERT_PERCENT: "140" }).contextFraction,
    ).toBe(DEFAULT_CONTEXT_FRACTION);
    expect(readUsageAlertThresholds({ JUANCODE_SESSION_SPEND_CAP_USD: "-3" }).spendCapUsd).toBe(0);
  });
});

describe("UsageAlertLatch — context", () => {
  const thresholds = { contextFraction: 0.8, spendCapUsd: 0, handoffTokens: 0 };

  it("fires once on the crossing, not on every reading in the band", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(sample(0.5))).toBeNull();
    expect(latch.consider(sample(0.79))).toBeNull();
    const alert = latch.consider(sample(0.81));
    expect(alert?.kind).toBe("context");
    expect(alert?.contextPercent).toBe(81);
    expect(alert?.contextTokens).toBe(162_000);
    expect(alert?.contextWindow).toBe(200_000);
    // Still climbing — the human has already been told.
    expect(latch.consider(sample(0.85))).toBeNull();
    expect(latch.consider(sample(0.99))).toBeNull();
  });

  it("re-arms after a compaction drops it clear of the line", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(sample(0.82))).not.toBeNull();
    // Hovering just under the line is not a compaction — no re-arm.
    expect(latch.consider(sample(0.8 - REARM_MARGIN / 2))).toBeNull();
    expect(latch.consider(sample(0.82))).toBeNull();
    // A real compaction, then filling up again.
    expect(latch.consider(sample(0.2))).toBeNull();
    expect(latch.consider(sample(0.83))).not.toBeNull();
  });

  it("stays silent when the window is unknown or context alerts are off", () => {
    expect(new UsageAlertLatch(thresholds).consider(sample(undefined))).toBeNull();
    const off = new UsageAlertLatch({ contextFraction: 0, spendCapUsd: 0, handoffTokens: 0 });
    expect(off.consider(sample(0.99))).toBeNull();
  });

  it("keeps latches per session", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(sample(0.9))).not.toBeNull();
    const other = { ...sample(0.9), sessionId: "s2" };
    expect(latch.consider(other)?.sessionId).toBe("s2");
  });

  it("forgets a session on request", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(sample(0.9))).not.toBeNull();
    latch.forget("s1");
    expect(latch.consider(sample(0.9))).not.toBeNull();
  });
});

describe("UsageAlertLatch — handoff", () => {
  const thresholds = { contextFraction: 0.8, spendCapUsd: 0, handoffTokens: 250_000 };

  /** A reading of `tokens` in a 1M window, where 250k is only 25% full. */
  function tokens(n: number): SessionUsageSample {
    return {
      sessionId: "s1",
      totalTokens: n,
      contextTokens: n,
      contextWindow: 1_000_000,
      contextFraction: n / 1_000_000,
    };
  }

  it("fires once on crossing the absolute line, long before the window fraction", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(tokens(249_999))).toBeNull();
    const alert = latch.consider(tokens(260_000));
    expect(alert?.kind).toBe("handoff");
    expect(alert?.contextTokens).toBe(260_000);
    expect(alert?.handoffTokens).toBe(250_000);
    expect(latch.consider(tokens(400_000))).toBeNull();
  });

  it("re-arms only once the context falls clear of the line", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(tokens(255_000))).not.toBeNull();
    expect(latch.consider(tokens(245_000))).toBeNull();
    expect(latch.consider(tokens(255_000))).toBeNull();
    expect(latch.consider(tokens(50_000))).toBeNull();
    expect(latch.consider(tokens(255_000))?.kind).toBe("handoff");
  });

  it("is independent of the context latch: both fire, context first", () => {
    const latch = new UsageAlertLatch(thresholds);
    const big = tokens(850_000);
    expect(latch.consider(big)?.kind).toBe("context");
    expect(latch.consider(big)?.kind).toBe("handoff");
    expect(latch.consider(big)).toBeNull();
  });

  it("stays silent when off or when the context size is unknown", () => {
    const off = new UsageAlertLatch({ ...thresholds, handoffTokens: 0 });
    expect(off.consider(tokens(300_000))).toBeNull();
    expect(
      new UsageAlertLatch(thresholds).consider({ sessionId: "s1", totalTokens: 900_000 }),
    ).toBeNull();
  });

  it("reads its line from the environment, 0 disabling and junk falling back", () => {
    expect(readUsageAlertThresholds({}).handoffTokens).toBe(DEFAULT_HANDOFF_TOKENS);
    expect(
      readUsageAlertThresholds({ JUANCODE_HANDOFF_ALERT_TOKENS: "180000" }).handoffTokens,
    ).toBe(180_000);
    expect(readUsageAlertThresholds({ JUANCODE_HANDOFF_ALERT_TOKENS: "0" }).handoffTokens).toBe(0);
    expect(readUsageAlertThresholds({ JUANCODE_HANDOFF_ALERT_TOKENS: "lots" }).handoffTokens).toBe(
      DEFAULT_HANDOFF_TOKENS,
    );
  });
});

describe("UsageAlertLatch — spend", () => {
  const thresholds = { contextFraction: 0, spendCapUsd: 10, handoffTokens: 0 };

  it("fires once when the estimate passes the cap", () => {
    const latch = new UsageAlertLatch(thresholds);
    expect(latch.consider(sample(undefined, 9.99))).toBeNull();
    const alert = latch.consider(sample(undefined, 10));
    expect(alert?.kind).toBe("spend");
    expect(alert?.spentUsd).toBe(10);
    expect(alert?.capUsd).toBe(10);
    // An estimate only grows, so a cap is crossed exactly once.
    expect(latch.consider(sample(undefined, 40))).toBeNull();
  });

  it("stays silent with no cap set, or with no cost estimate", () => {
    expect(
      new UsageAlertLatch({ contextFraction: 0, spendCapUsd: 0, handoffTokens: 0 }).consider(
        sample(undefined, 99),
      ),
    ).toBeNull();
    expect(new UsageAlertLatch(thresholds).consider(sample(undefined))).toBeNull();
  });

  it("reports context first when one reading trips both, then spend", () => {
    const latch = new UsageAlertLatch({ contextFraction: 0.8, spendCapUsd: 10, handoffTokens: 0 });
    const reading = sample(0.9, 12);
    expect(latch.consider(reading)?.kind).toBe("context");
    expect(latch.consider(reading)?.kind).toBe("spend");
    expect(latch.consider(reading)).toBeNull();
  });

  it("carries the dispatch id through so the alert can reach its chat", () => {
    const latch = new UsageAlertLatch(thresholds);
    const alert = latch.consider({ ...sample(undefined, 20), dispatchId: "d1" });
    expect(alert?.dispatchId).toBe("d1");
  });
});
