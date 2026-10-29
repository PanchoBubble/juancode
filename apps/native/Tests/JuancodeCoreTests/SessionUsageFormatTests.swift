import XCTest
@testable import JuancodeCore

final class SessionUsageFormatTests: XCTestCase {
    // MARK: - context pressure (juancode-lncw)

    private func withContext(_ tokens: Int?, _ window: Int?) -> SessionUsage {
        SessionUsage(
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 12_400, costUsd: 0.42,
            contextTokens: tokens, contextWindow: window)
    }

    func testContextFractionAndPercent() {
        let u = withContext(160_000, 200_000)
        XCTAssertEqual(u.contextFraction!, 0.8, accuracy: 1e-9)
        XCTAssertEqual(u.contextPercent, 80)
        XCTAssertEqual(u.contextPressure, .warn)
    }

    func testContextIsNilWhenEitherHalfIsUnknown() {
        XCTAssertNil(withContext(160_000, nil).contextFraction)
        XCTAssertNil(withContext(nil, 200_000).contextFraction)
        XCTAssertNil(withContext(160_000, 0).contextFraction)
        XCTAssertEqual(withContext(160_000, nil).contextPressure, .ok)
    }

    func testContextCanExceedTheWindow() {
        let u = withContext(210_000, 200_000)
        XCTAssertEqual(u.contextPercent, 105)
        XCTAssertEqual(u.contextPressure, .critical)
    }

    func testContextPressureThresholds() {
        XCTAssertEqual(withContext(159_000, 200_000).contextPressure, .ok)
        XCTAssertEqual(withContext(160_000, 200_000).contextPressure, .warn)
        XCTAssertEqual(withContext(189_000, 200_000).contextPressure, .warn)
        XCTAssertEqual(withContext(190_000, 200_000).contextPressure, .critical)
    }

    // MARK: - handoff line (juancode-u5q)

    func testHandoffLineIsAbsoluteTokensNotAWindowFraction() {
        // 250k of a 1M window is only 25% full, and already worth handing off.
        XCTAssertEqual(withContext(249_999, 1_000_000).contextPressure, .ok)
        XCTAssertEqual(withContext(250_000, 1_000_000).contextPressure, .handoff)
        XCTAssertEqual(withContext(600_000, 1_000_000).contextPressure, .handoff)
        // The window's own lines still win once they are reached.
        XCTAssertEqual(withContext(800_000, 1_000_000).contextPressure, .warn)
        XCTAssertEqual(withContext(950_000, 1_000_000).contextPressure, .critical)
        // An unknown window still knows the token count.
        XCTAssertEqual(withContext(300_000, nil).contextPressure, .handoff)
    }

    func testHandoffLineFollowsTheSettingAndZeroDisablesIt() {
        let u = withContext(180_000, 1_000_000)
        XCTAssertEqual(u.contextPressure, .ok)
        XCTAssertEqual(u.contextPressure(handoffTokens: 150_000), .handoff)
        XCTAssertEqual(withContext(400_000, 1_000_000).contextPressure(handoffTokens: 0), .ok)
        XCTAssertEqual(ContextPressure.of(fraction: nil, tokens: nil), .ok)
    }

    // MARK: - model price table (juancode-lncw)

    func testPriceTableMatchesByModelFamily() {
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8")?.inputPerMTok, 5)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5")?.outputPerMTok, 15)
        XCTAssertEqual(ModelPricing.price(for: "CLAUDE-HAIKU-4-5")?.inputPerMTok, 1)
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1")?.inputPerMTok, 10)
        XCTAssertNil(ModelPricing.price(for: "some-future-model"))
    }

    func testContextWindowDefaultsAndLongContextVariant() {
        XCTAssertEqual(ModelPricing.contextWindow(for: "claude-opus-5"), 200_000)
        XCTAssertEqual(ModelPricing.contextWindow(for: "claude-opus-5[1m]"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextWindow(for: "claude-sonnet-5-1m"), 1_000_000)
        XCTAssertNil(ModelPricing.contextWindow(for: "some-future-model"))
    }

    func testTurnCostAppliesCacheMultipliers() {
        // opus: $5/MTok in, $25/MTok out, cache read 0.1x, cache write 1.25x.
        let cost = ModelPricing.turnCost(
            model: "claude-opus-4-8", input: 1000, output: 200,
            cacheRead: 5000, cacheWrite: 800)!
        let inCost: Double = 1000 * 5
        let cacheReadCost: Double = 5000 * 0.5
        let cacheWriteCost: Double = 800 * 6.25
        let outCost: Double = 200 * 25
        let expected: Double = (inCost + cacheReadCost + cacheWriteCost + outCost) / 1_000_000
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
        XCTAssertNil(ModelPricing.turnCost(
            model: "some-future-model", input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
    }

    // MARK: - aggregateUsage (mirrors web aggregateUsage)

    private func meta(_ id: String, _ usage: SessionUsage?) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: "/x", title: id,
            status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
            cliSessionId: nil, skipPermissions: false, worktreePath: nil,
            usage: usage)
    }

    func testAggregateReturnsNilWhenNoUsage() {
        XCTAssertNil([meta("a", nil), meta("b", nil)].aggregateUsage())
        XCTAssertNil([SessionMeta]().aggregateUsage())
    }

    func testAggregateSumsTokensAndMixesCost() {
        let priced = SessionUsage(
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 10,
            cacheWriteTokens: 5, totalTokens: 165, costUsd: 0.25)
        let unpriced = SessionUsage(
            inputTokens: 200, outputTokens: 60, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 260, costUsd: nil)
        let agg = [meta("a", priced), meta("b", unpriced), meta("c", nil)]
            .aggregateUsage()!
        XCTAssertEqual(agg.inputTokens, 300)
        XCTAssertEqual(agg.outputTokens, 110)
        XCTAssertEqual(agg.cacheReadTokens, 10)
        XCTAssertEqual(agg.cacheWriteTokens, 5)
        XCTAssertEqual(agg.totalTokens, 425)
        // Partial cost: only the priced session contributes.
        XCTAssertEqual(agg.costUsd!, 0.25, accuracy: 1e-9)
    }

    func testAggregateDropsContextBecauseWindowsDoNotSum() {
        let a = withContext(100_000, 200_000)
        let b = withContext(180_000, 200_000)
        let agg = [meta("a", a), meta("b", b)].aggregateUsage()!
        XCTAssertNil(agg.contextTokens)
        XCTAssertNil(agg.contextWindow)
        XCTAssertNil(agg.contextFraction)
        XCTAssertEqual(agg.badgeLabel, "25k tok · $0.84")
    }

    func testAggregateCostNilWhenNoneePriced() {
        let unpriced = SessionUsage(
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 2, costUsd: nil)
        let agg = [meta("a", unpriced)].aggregateUsage()!
        XCTAssertEqual(agg.totalTokens, 2)
        XCTAssertNil(agg.costUsd)
    }
}
