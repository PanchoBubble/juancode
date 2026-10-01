import XCTest
@testable import JuancodeCore

final class WaitingSessionsTests: XCTestCase {
    private func c(_ id: String, live: Bool = true, agent: Bool = true) -> GlobalPause.Candidate {
        .init(id: id, isLive: live, isAgent: agent)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testCountsOnlyLiveAgentsWaitingForInput() {
        let out = WaitingSessions.project(
            [c("waiting"), c("busy"), c("idle"), c("unknown"),
             c("asleep", live: false), c("editor", agent: false)],
            activities: ["waiting": .waitingInput, "busy": .busy, "idle": .idle,
                         "asleep": .waitingInput, "editor": .waitingInput],
            since: [:])
        XCTAssertEqual(out.map(\.id), ["waiting"])
    }

    func testLongestWaitFirstAndUnknownSinceLast() {
        let out = WaitingSessions.project(
            [c("a"), c("b"), c("c"), c("d")],
            activities: ["a": .waitingInput, "b": .waitingInput, "c": .waitingInput,
                         "d": .waitingInput],
            since: ["a": t0.addingTimeInterval(30), "c": t0, "d": t0.addingTimeInterval(30)])
        XCTAssertEqual(out.map(\.id), ["c", "a", "d", "b"])
        XCTAssertEqual(out.first?.since, t0)
        XCTAssertNil(out.last?.since)
    }

    func testEqualWhenNothingMoved() {
        let args = ([c("a"), c("b")], ["a": SessionActivity.waitingInput, "b": .busy], ["a": t0])
        XCTAssertEqual(WaitingSessions.project(args.0, activities: args.1, since: args.2),
                       WaitingSessions.project(args.0, activities: ["a": .waitingInput, "b": .idle],
                                               since: args.2))
    }

    func testElapsedLabels() {
        XCTAssertEqual(WaitingSessions.elapsed(since: t0, now: t0.addingTimeInterval(-5)), "0s")
        XCTAssertEqual(WaitingSessions.elapsed(since: t0, now: t0.addingTimeInterval(42)), "42s")
        XCTAssertEqual(WaitingSessions.elapsed(since: t0, now: t0.addingTimeInterval(4 * 60 + 59)), "4m")
        XCTAssertEqual(WaitingSessions.elapsed(since: t0, now: t0.addingTimeInterval(2 * 3600)), "2h")
        XCTAssertEqual(WaitingSessions.elapsed(since: t0, now: t0.addingTimeInterval(3 * 86400)), "3d")
    }
}
