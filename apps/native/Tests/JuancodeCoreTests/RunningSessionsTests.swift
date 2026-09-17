import XCTest
@testable import JuancodeCore

final class RunningSessionsTests: XCTestCase {
    private func r(_ id: String, _ activity: SessionActivity?) -> RunningSessions.Row {
        .init(id: id, activity: activity)
    }

    func testWorkingFirstThenWaitingThenResting() {
        let ordered = RunningSessions.order([
            r("idle", .idle), r("waiting", .waitingInput), r("busy", .busy),
        ])
        XCTAssertEqual(ordered.map(\.id), ["busy", "waiting", "idle"])
    }

    func testKeepsGivenOrderWithinABucket() {
        let ordered = RunningSessions.order([
            r("b1", .busy), r("b2", .busy), r("b3", .busy),
        ])
        XCTAssertEqual(ordered.map(\.id), ["b1", "b2", "b3"])
    }

    func testUnknownActivitySortsWithTheRestingOnes() {
        let ordered = RunningSessions.order([r("unknown", nil), r("busy", .busy), r("idle", .idle)])
        XCTAssertEqual(ordered.map(\.id), ["busy", "unknown", "idle"])
    }
}
