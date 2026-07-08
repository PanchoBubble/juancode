import XCTest
@testable import JuancodeServer

/// Classification of remote `input` frames for the dead-session revive path
/// (juancode-23m): only one complete bracketed paste — the shape the oracle
/// sidecar's reply path sends — counts as a message; raw keystrokes must not
/// trigger a revival.
final class BracketedPasteMessageTests: XCTestCase {
    private let start = "\u{1B}[200~"
    private let end = "\u{1B}[201~"

    func testCompletePasteYieldsItsBody() {
        XCTAssertEqual(bracketedPasteMessage("\(start)fix the tests\(end)"), "fix the tests")
    }

    func testTrailingSubmitCrOrLfIsTolerated() {
        // Some clients append the submitting Enter to the same frame.
        XCTAssertEqual(bracketedPasteMessage("\(start)go\(end)\r"), "go")
        XCTAssertEqual(bracketedPasteMessage("\(start)go\(end)\r\n"), "go")
    }

    func testMultilineBodySurvives() {
        XCTAssertEqual(bracketedPasteMessage("\(start)line one\nline two\(end)"), "line one\nline two")
    }

    func testRawKeystrokesAreNotMessages() {
        XCTAssertNil(bracketedPasteMessage("\r"))          // the sidecar's follow-up Enter
        XCTAssertNil(bracketedPasteMessage("y"))           // a single typed key
        XCTAssertNil(bracketedPasteMessage("plain text"))  // unbracketed burst
        XCTAssertNil(bracketedPasteMessage(""))
    }

    func testPartialOrCompoundPastesAreNotMessages() {
        XCTAssertNil(bracketedPasteMessage("\(start)unterminated"))     // paste still streaming
        XCTAssertNil(bracketedPasteMessage("terminated only\(end)"))    // tail of a split paste
        XCTAssertNil(bracketedPasteMessage("\(start)a\(end)x"))         // keystrokes after the paste
        XCTAssertNil(bracketedPasteMessage("\(start)a\(end)\(start)b\(end)")) // two pastes in one frame
    }
}
