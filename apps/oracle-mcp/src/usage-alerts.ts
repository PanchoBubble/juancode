// Threshold alerts over per-session usage (juancode-lncw): the sidecar half of
// cost/context telemetry. The native app derives the numbers from the CLI's own
// transcripts and puts them on `SessionMeta.usage`; this module decides which of
// those readings is worth waking a human for.
//
// The whole design constraint is "once per crossing, not per event". The usage poll
// lands a fresh reading every few seconds while an agent streams, so a naive
// `fraction >= 0.8` test would ping on every tick for the rest of the session. The
// latch below fires on the edge INTO the alert band and then stays quiet until the
// session drops back out of it (which a compaction does), at which point it re-arms.
//
// Pure and dependency-free — no Telegram, no WS, no clock — so the crossing logic is
// unit-testable on its own; `telegram.ts` owns the sending.

import type { SessionUsageSample } from "./native-events.ts";

/** Default context warn line, mirroring `ContextPressure.warnFraction` in the Swift
 *  core. Kept in agreement by hand: the core needs it for the badge tint, the
 *  sidecar for the ping, and neither reads the other's settings. */
export const DEFAULT_CONTEXT_FRACTION = 0.8;

/** How far back below the line a session has to fall before another crossing can
 *  fire. Without it a reading hovering on the boundary would alternate in and out of
 *  the band and ping on every re-entry. */
export const REARM_MARGIN = 0.05;

export interface UsageAlertThresholds {
  /** Context fraction that trips an alert; 0 disables context alerts. */
  contextFraction: number;
  /** Estimated spend (USD) on ONE session that trips an alert; 0 disables. */
  spendCapUsd: number;
}

/** Read the thresholds from the environment.
 *
 *  `JUANCODE_CONTEXT_ALERT_PERCENT` is a percentage (80 → 0.8) because that is how
 *  it reads in the message; 0 turns context alerts off. `JUANCODE_SESSION_SPEND_CAP_USD`
 *  is off unless set — a spend cap is a personal number, so there is no sensible
 *  default to impose. Both fall back to the default on anything unparseable rather
 *  than throwing at startup. */
export function readUsageAlertThresholds(
  env: NodeJS.ProcessEnv = process.env,
): UsageAlertThresholds {
  const rawPercent = (env.JUANCODE_CONTEXT_ALERT_PERCENT ?? "").trim();
  const percent = rawPercent === "" ? NaN : Number(rawPercent);
  const contextFraction =
    Number.isFinite(percent) && percent >= 0 && percent <= 100
      ? percent / 100
      : DEFAULT_CONTEXT_FRACTION;

  const rawCap = (env.JUANCODE_SESSION_SPEND_CAP_USD ?? "").trim();
  const cap = rawCap === "" ? NaN : Number(rawCap);
  const spendCapUsd = Number.isFinite(cap) && cap > 0 ? cap : 0;

  return { contextFraction, spendCapUsd };
}

export type UsageAlertKind = "context" | "spend";

export interface UsageAlert {
  sessionId: string;
  kind: UsageAlertKind;
  /** Context occupancy as a whole percent — always set for a "context" alert. */
  contextPercent?: number;
  contextTokens?: number;
  contextWindow?: number;
  /** Estimated spend to date — always set for a "spend" alert. */
  spentUsd?: number;
  capUsd?: number;
  dispatchId?: string;
}

/** Per-session record of which bands we have already alerted on. */
interface LatchState {
  context: boolean;
  spend: boolean;
}

/**
 * Edge detector over the usage stream: one alert per crossing.
 *
 * Context re-arms — a compaction genuinely drops the conversation back down, and
 * refilling the window afterwards is worth hearing about a second time. Spend does
 * not: an estimate only ever grows, so a cap is crossed exactly once per session.
 */
export class UsageAlertLatch {
  private readonly state = new Map<string, LatchState>();

  constructor(private readonly thresholds: UsageAlertThresholds) {}

  /** Fold one reading in and return the alert it crossed into, or null.
   *
   *  Context is checked before spend so a session that trips both on the same
   *  reading reports the one with a deadline attached; the spend latch stays armed
   *  and fires on the next reading. */
  consider(sample: SessionUsageSample): UsageAlert | null {
    const latch = this.state.get(sample.sessionId) ?? { context: false, spend: false };
    this.state.set(sample.sessionId, latch);

    const contextAlert = this.considerContext(sample, latch);
    if (contextAlert) return contextAlert;
    return this.considerSpend(sample, latch);
  }

  private considerContext(sample: SessionUsageSample, latch: LatchState): UsageAlert | null {
    const line = this.thresholds.contextFraction;
    if (line <= 0) return null;
    const fraction = sample.contextFraction;
    if (fraction === undefined) return null;

    if (fraction < line - REARM_MARGIN) latch.context = false;
    if (fraction < line || latch.context) return null;
    latch.context = true;

    const alert: UsageAlert = {
      sessionId: sample.sessionId,
      kind: "context",
      contextPercent: Math.round(fraction * 100),
    };
    if (sample.contextTokens !== undefined) alert.contextTokens = sample.contextTokens;
    if (sample.contextWindow !== undefined) alert.contextWindow = sample.contextWindow;
    if (sample.costUsd !== undefined) alert.spentUsd = sample.costUsd;
    if (sample.dispatchId) alert.dispatchId = sample.dispatchId;
    return alert;
  }

  private considerSpend(sample: SessionUsageSample, latch: LatchState): UsageAlert | null {
    const cap = this.thresholds.spendCapUsd;
    if (cap <= 0) return null;
    const spent = sample.costUsd;
    if (spent === undefined) return null;
    if (spent < cap || latch.spend) return null;
    latch.spend = true;

    const alert: UsageAlert = {
      sessionId: sample.sessionId,
      kind: "spend",
      spentUsd: spent,
      capUsd: cap,
    };
    if (sample.dispatchId) alert.dispatchId = sample.dispatchId;
    return alert;
  }

  /** Drop a session's latches (it exited, or was restarted fresh). */
  forget(sessionId: string): void {
    this.state.delete(sessionId);
  }
}

/** The alert as one line of Telegram text, without the session header
 *  `telegram.ts` puts in front of it. */
export function usageAlertLine(alert: UsageAlert): string {
  if (alert.kind === "spend") {
    return `💸 est. spend $${(alert.spentUsd ?? 0).toFixed(2)} — past your $${(
      alert.capUsd ?? 0
    ).toFixed(2)} cap for one session.`;
  }
  const of =
    alert.contextTokens !== undefined && alert.contextWindow !== undefined
      ? ` (${alert.contextTokens.toLocaleString("en-US")} of ${alert.contextWindow.toLocaleString(
          "en-US",
        )} tokens)`
      : "";
  const spend = alert.spentUsd !== undefined ? ` · est. spend $${alert.spentUsd.toFixed(2)}` : "";
  return `🧠 context ${alert.contextPercent}% full${of}${spend}.`;
}
