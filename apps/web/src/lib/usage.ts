import type { SessionMeta, SessionUsage } from "../protocol.ts";

/** Compact token count: 980 → "980", 12_400 → "12.4k", 3_200_000 → "3.2M". */
export function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

/** Cost as a short USD string, or null when there's no real cost to show. */
export function formatCost(usd: number | null): string | null {
  if (usd == null) return null;
  if (usd === 0) return "$0.00";
  if (usd < 0.01) return "<$0.01";
  return `$${usd.toFixed(2)}`;
}

/** Multi-line breakdown for a tooltip. */
export function usageTooltip(u: SessionUsage): string {
  const lines = [
    `Input: ${u.inputTokens.toLocaleString()}`,
    `Output: ${u.outputTokens.toLocaleString()}`,
    `Cache read: ${u.cacheReadTokens.toLocaleString()}`,
    `Cache write: ${u.cacheWriteTokens.toLocaleString()}`,
    `Total: ${u.totalTokens.toLocaleString()} tokens`,
  ];
  const cost = formatCost(u.costUsd);
  if (cost) lines.push(`Cost: ${cost}`);
  return lines.join("\n");
}

/**
 * Sum usage across sessions. `totalTokens` always sums; `costUsd` sums only the
 * sessions that report a real cost and stays null when none do — so a mix of
 * sessions with and without a reported cost still shows the partial total.
 */
export function aggregateUsage(sessions: SessionMeta[]): SessionUsage | null {
  const withUsage = sessions.filter((s) => s.usage);
  if (withUsage.length === 0) return null;
  const total: SessionUsage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 0,
    costUsd: null,
  };
  for (const s of withUsage) {
    const u = s.usage!;
    total.inputTokens += u.inputTokens;
    total.outputTokens += u.outputTokens;
    total.cacheReadTokens += u.cacheReadTokens;
    total.cacheWriteTokens += u.cacheWriteTokens;
    total.totalTokens += u.totalTokens;
    if (u.costUsd != null) total.costUsd = (total.costUsd ?? 0) + u.costUsd;
  }
  return total;
}
