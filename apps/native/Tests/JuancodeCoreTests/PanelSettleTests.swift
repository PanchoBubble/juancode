import XCTest
@testable import JuancodeCore

/// The gate that keeps the Oracle drawer's open smooth: the panel slides
/// immediately, and work that would repaint the terminal under it waits out the
/// slide plus a quiet beat.
final class PanelSettleTests: XCTestCase {

    func testNoSlideInFlightRunsTheWorkImmediately() {
        // Acting on an already-open dock (rail tap, a second ask) must not feel laggy.
        XCTAssertEqual(PanelSettle.waitMs(sinceSlideStartMs: nil), 0)
    }

    func testWaitsOutTheRestOfTheSlidePlusTheBeat() {
        XCTAssertEqual(PanelSettle.waitMs(sinceSlideStartMs: 0), PanelSettle.windowMs)
        XCTAssertEqual(PanelSettle.waitMs(sinceSlideStartMs: 60), PanelSettle.windowMs - 60)
    }

    func testASettledSlideNoLongerHoldsAnything() {
        XCTAssertEqual(PanelSettle.waitMs(sinceSlideStartMs: PanelSettle.windowMs), 0)
        XCTAssertEqual(PanelSettle.waitMs(sinceSlideStartMs: PanelSettle.windowMs + 500), 0)
    }

    func testTheBeatIsTheDebounceOnTopOfTheSlide() {
        XCTAssertEqual(PanelSettle.windowMs, PanelSettle.slideMs + PanelSettle.debounceMs)
        XCTAssertEqual(PanelSettle.debounceMs, 100)
    }
}
