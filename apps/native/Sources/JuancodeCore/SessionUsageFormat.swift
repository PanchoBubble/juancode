import Foundation

/// Display formatting for `SessionUsage`, mirroring `apps/web/src/lib/usage.ts`
/// so the native shell labels tokens/cost exactly like the web UI does.
public enum SessionUsageFormat {
    /// Compact token count: 980 → "980", 12_400 → "12.4k", 3_200_000 → "3.2M".
    /// Mirrors the web `formatTokens`.
    public static func tokens(_ n: Int) -> String {
        if n < 1000 { return String(n) }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return n < 10_000 ? String(format: "%.1fk", k) : String(format: "%.0fk", k)
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// Estimated cost as a short USD string, or nil when cost is unknown.
    /// Mirrors the web `formatCost`.
    public static func cost(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    /// Context occupancy as "ctx 64%", or nil when the window isn't known
    /// (juancode-lncw). Deliberately not clamped at 100%: a session that briefly
    /// overshoots its window before the CLI compacts should say so.
    public static func context(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        return "ctx \(percent)%"
    }
}

extension SessionUsage {
    /// Compact "12.4k tok" label, with " · $0.42" appended when cost is known and
    /// " · ctx 64%" when the context window is (juancode-lncw). Nil when there's
    /// nothing worth showing (no tokens). Mirrors `UsageBadge`.
    public var badgeLabel: String? {
        guard totalTokens > 0 else { return nil }
        var s = "\(SessionUsageFormat.tokens(totalTokens)) tok"
        if let c = SessionUsageFormat.cost(costUsd) { s += " · \(c)" }
        if let ctx = SessionUsageFormat.context(contextPercent) { s += " · \(ctx)" }
        return s
    }
}

extension Array where Element == SessionMeta {
    /// Sum usage across these sessions. `totalTokens` always sums; `costUsd` sums
    /// only the sessions that report a cost (nil when none do) — so a mix of
    /// priced (Claude) and unpriced (Codex) sessions still shows the partial
    /// estimate. Returns nil when no session has usage. Mirrors `aggregateUsage`.
    ///
    /// Context deliberately does NOT aggregate: each session fills its own window,
    /// so a summed occupancy (or a summed window) means nothing. The rollup keeps
    /// both nil, which drops the "ctx" clause from the total's label.
    public func aggregateUsage() -> SessionUsage? {
        let withUsage = compactMap(\.usage)
        guard !withUsage.isEmpty else { return nil }
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0
        var cost: Double?
        for u in withUsage {
            input += u.inputTokens
            output += u.outputTokens
            cacheRead += u.cacheReadTokens
            cacheWrite += u.cacheWriteTokens
            total += u.totalTokens
            if let c = u.costUsd { cost = (cost ?? 0) + c }
        }
        return SessionUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: total,
            costUsd: cost)
    }
}
