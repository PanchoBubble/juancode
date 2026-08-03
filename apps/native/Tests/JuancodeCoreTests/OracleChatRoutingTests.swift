import XCTest
@testable import JuancodeCore

/// Where a rail tap / start-CTA sends the Oracle chat. The regression these cover:
/// an Oracle whose pty exited while it was the active chat was unrevivable in place —
/// the tap was swallowed by an identity guard and the CTA adopted a different Oracle,
/// so the only way back in was to select another Oracle and re-select this one.
final class OracleChatRoutingTests: XCTestCase {

    // MARK: - rail tap

    func testTappingTheActiveLiveOracleIsANoOp() {
        XCTAssertEqual(OracleChatRouting.select("a", active: "a", isLive: true), .none)
    }

    func testTappingTheActiveButDeadOracleRevivesItInPlace() {
        XCTAssertEqual(OracleChatRouting.select("a", active: "a", isLive: false), .revive("a"))
    }

    func testTappingAnotherLiveOracleJustFocusesIt() {
        XCTAssertEqual(OracleChatRouting.select("b", active: "a", isLive: true), .focus("b"))
    }

    func testTappingAnotherDeadOracleRevivesIt() {
        XCTAssertEqual(OracleChatRouting.select("b", active: "a", isLive: false), .revive("b"))
    }

    func testTappingWithNoActiveChatStillRoutesByLiveness() {
        XCTAssertEqual(OracleChatRouting.select("a", active: nil, isLive: true), .focus("a"))
        XCTAssertEqual(OracleChatRouting.select("a", active: nil, isLive: false), .revive("a"))
    }

    // MARK: - start / resume CTA

    func testCtaRevivesTheOracleTheUserIsLookingAt() {
        // Even with another Oracle running: the CTA sits under THIS conversation, so
        // adopting the other one would swap the chat out from under the user.
        XCTAssertEqual(
            OracleChatRouting.start(active: "a", activeIsResumable: true,
                                    otherLive: "b", mostRecent: "c"),
            .revive("a"))
    }

    func testCtaAdoptsALiveOracleWhenTheActiveOneIsGoneForGood() {
        // Active id no longer has a persisted row (deleted / pruned) — nothing to resume.
        XCTAssertEqual(
            OracleChatRouting.start(active: "a", activeIsResumable: false,
                                    otherLive: "b", mostRecent: "c"),
            .adopt("b"))
    }

    func testCtaFallsBackToTheMostRecentPastOracle() {
        XCTAssertEqual(
            OracleChatRouting.start(active: nil, activeIsResumable: false,
                                    otherLive: nil, mostRecent: "c"),
            .revive("c"))
    }

    func testCtaSpawnsFreshWithNoOracleToContinue() {
        XCTAssertEqual(
            OracleChatRouting.start(active: nil, activeIsResumable: false,
                                    otherLive: nil, mostRecent: nil),
            .spawnFresh)
    }

    func testCtaIgnoresAnUnresumableActiveIdRatherThanDeadEnding() {
        XCTAssertEqual(
            OracleChatRouting.start(active: "a", activeIsResumable: false,
                                    otherLive: nil, mostRecent: nil),
            .spawnFresh)
    }
}
