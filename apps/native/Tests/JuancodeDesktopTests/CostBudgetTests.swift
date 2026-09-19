import XCTest
@testable import JuancodeDesktop

/// Unit tests for the cost-budget evaluation math (juancode-qoc). Pure — no store,
/// no UI.
final class CostBudgetTests: XCTestCase {
    func testOffWhenNoBudget() {
        XCTAssertEqual(evaluateBudget(spentUsd: 5, budgetUsd: 0, warnPercent: 80).level, .off)
        XCTAssertEqual(evaluateBudget(spentUsd: 5, budgetUsd: -1, warnPercent: 80).level, .off)
    }

    func testOffWhenSpendUnknown() {
        XCTAssertEqual(evaluateBudget(spentUsd: nil, budgetUsd: 20, warnPercent: 80).level, .off)
    }

    func testUnderWarnIsOk() {
        let s = evaluateBudget(spentUsd: 10, budgetUsd: 20, warnPercent: 80)
        XCTAssertEqual(s.level, .ok)
        XCTAssertEqual(s.fraction, 0.5, accuracy: 0.0001)
    }

    func testAtWarnThresholdIsWarn() {
        // 16/20 = 80% == warn threshold → warn.
        XCTAssertEqual(evaluateBudget(spentUsd: 16, budgetUsd: 20, warnPercent: 80).level, .warn)
        // Just under → ok.
        XCTAssertEqual(evaluateBudget(spentUsd: 15.99, budgetUsd: 20, warnPercent: 80).level, .ok)
    }

    func testAtOrOverBudgetIsOver() {
        XCTAssertEqual(evaluateBudget(spentUsd: 20, budgetUsd: 20, warnPercent: 80).level, .over)
        XCTAssertEqual(evaluateBudget(spentUsd: 25, budgetUsd: 20, warnPercent: 80).level, .over)
    }

    func testProgressLabel() {
        XCTAssertEqual(evaluateBudget(spentUsd: 5, budgetUsd: 20, warnPercent: 80).progressLabel, "25% of $20")
        XCTAssertNil(evaluateBudget(spentUsd: 5, budgetUsd: 0, warnPercent: 80).progressLabel)
        // Non-integer budget keeps cents.
        XCTAssertEqual(evaluateBudget(spentUsd: 2.5, budgetUsd: 12.5, warnPercent: 80).progressLabel, "20% of $12.50")
    }
}
