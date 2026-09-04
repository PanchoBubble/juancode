import XCTest
@testable import JuancodeCore

final class GlobalPauseTests: XCTestCase {
    private func c(_ id: String, live: Bool = true, agent: Bool = true) -> GlobalPause.Candidate {
        .init(id: id, isLive: live, isAgent: agent)
    }

    func testPausesEveryLiveAgent() {
        let targets = GlobalPause.targets([c("a"), c("b"), c("c")])
        XCTAssertEqual(targets, ["a", "b", "c"])
    }

    func testSkipsSleepingAndEditorPanes() {
        let targets = GlobalPause.targets([
            c("live"), c("asleep", live: false), c("editor", agent: false),
        ])
        XCTAssertEqual(targets, ["live"])
    }

    func testRevivesOnlyThePausedSetThatIsStillAsleep() {
        // "woke" came back on its own while paused; "gone" left the sidebar.
        let revivals = GlobalPause.revivals(
            paused: ["a", "woke", "gone"],
            present: [c("a", live: false), c("woke"), c("other", live: false)],
            focus: nil)
        XCTAssertEqual(revivals, ["a"])
    }

    func testFocusRevivesFirst() {
        let present = [c("a", live: false), c("b", live: false), c("c", live: false)]
        let revivals = GlobalPause.revivals(paused: ["a", "b", "c"], present: present, focus: "c")
        XCTAssertEqual(revivals, ["c", "a", "b"])
    }

    func testFocusOutsideTheSetChangesNothing() {
        let present = [c("a", live: false), c("b", live: false)]
        let revivals = GlobalPause.revivals(paused: ["a", "b"], present: present, focus: "zzz")
        XCTAssertEqual(revivals, ["a", "b"])
    }

    func testLanesDealRoundRobinSoTheHeadStartsEarly() {
        XCTAssertEqual(GlobalPause.lanes(["1", "2", "3", "4", "5"], lanes: 2),
                       [["1", "3", "5"], ["2", "4"]])
    }

    func testLanesNeverExceedTheItemCount() {
        XCTAssertEqual(GlobalPause.lanes(["only"], lanes: 4), [["only"]])
        XCTAssertTrue(GlobalPause.lanes([], lanes: 4).isEmpty)
    }
}
