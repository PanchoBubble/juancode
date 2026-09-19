import Foundation

/// Cost-budget evaluation (juancode-qoc): compares estimated spend against a
/// user-set USD budget and reports whether it's under, near (past the warn
/// threshold), or over. Pure and dependency-free so it's unit-testable and shared
/// by the sidebar total + settings without any UI/store deps. The spend itself is
/// derived from `SessionUsage.costUsd` upstream (see `aggregateUsage`).

public enum BudgetLevel: Sendable, Equatable {
    /// No budget set (budget ≤ 0) or spend unknown — nothing to warn about.
    case off
    /// Under the warn threshold.
    case ok
    /// At/over the warn threshold but under budget.
    case warn
    /// At/over budget.
    case over
}

public struct BudgetStatus: Sendable, Equatable {
    public let level: BudgetLevel
    /// spent / budget, clamped ≥ 0. Zero when `off`.
    public let fraction: Double
    public let spentUsd: Double
    public let budgetUsd: Double

    public init(level: BudgetLevel, fraction: Double, spentUsd: Double, budgetUsd: Double) {
        self.level = level
        self.fraction = fraction
        self.spentUsd = spentUsd
        self.budgetUsd = budgetUsd
    }

    /// A short "· 82% of $20" suffix for the usage footer, or nil when off.
    public var progressLabel: String? {
        guard level != .off else { return nil }
        let pct = Int((fraction * 100).rounded())
        let budget = budgetUsd == budgetUsd.rounded() ? String(format: "$%.0f", budgetUsd)
                                                      : String(format: "$%.2f", budgetUsd)
        return "\(pct)% of \(budget)"
    }
}

/// Evaluate `spentUsd` against `budgetUsd` (a warn at `warnPercent` of budget).
/// `budgetUsd <= 0` (unset) or a nil spend ⇒ `.off`. Pure.
public func evaluateBudget(spentUsd: Double?, budgetUsd: Double, warnPercent: Int) -> BudgetStatus {
    guard budgetUsd > 0, let spent = spentUsd else {
        return BudgetStatus(level: .off, fraction: 0, spentUsd: spentUsd ?? 0, budgetUsd: budgetUsd)
    }
    let fraction = max(0, spent / budgetUsd)
    let warn = Double(min(100, max(0, warnPercent))) / 100
    let level: BudgetLevel = fraction >= 1 ? .over : (fraction >= warn ? .warn : .ok)
    return BudgetStatus(level: level, fraction: fraction, spentUsd: spent, budgetUsd: budgetUsd)
}
