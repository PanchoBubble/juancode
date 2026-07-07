import type { SessionUsage } from "../protocol.ts";
import { formatCost, formatTokens, usageTooltip } from "../lib/usage.ts";

/**
 * Compact token (and cost) readout for a session or an aggregate. Renders
 * nothing when there's no usage yet. The full per-bucket breakdown is in the
 * hover tooltip; cost is shown only when the CLI reported a real one.
 */
export function UsageBadge({
  usage,
  className = "",
}: {
  usage: SessionUsage | null | undefined;
  className?: string;
}) {
  if (!usage || usage.totalTokens === 0) return null;
  const cost = formatCost(usage.costUsd);
  return (
    <span
      title={usageTooltip(usage)}
      className={`inline-flex items-center gap-1 font-mono tabular-nums ${className}`}
    >
      <span>{formatTokens(usage.totalTokens)} tok</span>
      {cost && <span className="text-neutral-500">· {cost}</span>}
    </span>
  );
}
