import XCTest
@testable import JuancodeCore

final class TerminalHitClipTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testNoInsetAcceptsEverything() {
        for y in [0.0, 300.0, 600.0] {
            XCTAssertFalse(TerminalHitClip.rejects(point: CGPoint(x: 10, y: y), bounds: bounds,
                                                   flipped: false, topInset: 0))
        }
    }

    func testUnflippedRejectsOnlyTheTranslatedBand() {
        // Unflipped: the top edge is maxY, so the off-screen band is the high-y end.
        XCTAssertTrue(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 590), bounds: bounds,
                                              flipped: false, topInset: 240))
        XCTAssertTrue(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 361), bounds: bounds,
                                              flipped: false, topInset: 240))
        // The first visible row and everything below it still belong to the terminal.
        XCTAssertFalse(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 360), bounds: bounds,
                                               flipped: false, topInset: 240))
        XCTAssertFalse(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 0), bounds: bounds,
                                               flipped: false, topInset: 240))
    }

    func testFlippedRejectsOnlyTheTranslatedBand() {
        XCTAssertTrue(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 0), bounds: bounds,
                                              flipped: true, topInset: 240))
        XCTAssertTrue(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 239), bounds: bounds,
                                              flipped: true, topInset: 240))
        XCTAssertFalse(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 240), bounds: bounds,
                                               flipped: true, topInset: 240))
        XCTAssertFalse(TerminalHitClip.rejects(point: CGPoint(x: 10, y: 600), bounds: bounds,
                                               flipped: true, topInset: 240))
    }
}
