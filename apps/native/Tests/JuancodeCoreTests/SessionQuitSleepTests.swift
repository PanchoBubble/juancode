import XCTest
@testable import JuancodeCore

/// Quit-sleep labelling, moved here with `SessionQuitSleep` when the Swift session
/// reaper was deleted. The reason a quit stamps is per session on purpose: a flat
/// `.quit` across a bulk sleep read identically whether or not it interrupted work.
final class SessionQuitSleepTests: XCTestCase {
    func testQuitSleepReasonRecordsWhatWasInterrupted() {
        XCTAssertEqual(SessionQuitSleep.reason(for: .busy), .quitBusy)
        XCTAssertEqual(SessionQuitSleep.reason(for: .waitingInput), .quitWaitingInput)
        XCTAssertTrue(SessionQuitSleep.reason(for: .busy).workInFlight)
        XCTAssertTrue(SessionQuitSleep.reason(for: .waitingInput).workInFlight)
    }

    func testQuitSleepReasonForIdleCarriesNoWork() {
        XCTAssertEqual(SessionQuitSleep.reason(for: .idle), .quit)
        XCTAssertFalse(SessionQuitSleep.reason(for: .idle).workInFlight)
    }

    func testWouldInterruptWorkIsTheBatchRollUp() {
        XCTAssertFalse(SessionQuitSleep.wouldInterruptWork([]))
        XCTAssertFalse(SessionQuitSleep.wouldInterruptWork([.idle, .idle]))
        XCTAssertTrue(SessionQuitSleep.wouldInterruptWork([.idle, .busy]))
        XCTAssertTrue(SessionQuitSleep.wouldInterruptWork([.idle, .waitingInput]))
    }
}
