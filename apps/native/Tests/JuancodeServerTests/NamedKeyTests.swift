import XCTest
@testable import JuancodeServer

/// The named-key vocabulary (juancode-uigs): the table a remote client's Esc button
/// resolves through, and the refusal that stops an unknown name being typed as text.
final class NamedKeyTests: XCTestCase {
    func testNamedKeysResolveToTheBytesATerminalExpects() {
        XCTAssertEqual(NamedKey.bytes(for: "Enter"), [0x0D])
        XCTAssertEqual(NamedKey.bytes(for: "Escape"), [0x1B])
        XCTAssertEqual(NamedKey.bytes(for: "Tab"), [0x09])
        XCTAssertEqual(NamedKey.bytes(for: "Backspace"), [0x7F])
        XCTAssertEqual(NamedKey.bytes(for: "Space"), [0x20])
        XCTAssertEqual(NamedKey.bytes(for: "Up"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(NamedKey.bytes(for: "Down"), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(NamedKey.bytes(for: "Right"), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(NamedKey.bytes(for: "Left"), [0x1B, 0x5B, 0x44])
    }

    func testEveryControlLetterIsItsPositionInTheAlphabet() {
        XCTAssertEqual(NamedKey.bytes(for: "C-a"), [0x01])
        XCTAssertEqual(NamedKey.bytes(for: "C-c"), [0x03])
        XCTAssertEqual(NamedKey.bytes(for: "C-d"), [0x04])
        XCTAssertEqual(NamedKey.bytes(for: "C-z"), [0x1A])
    }

    func testSpellingIsForgivingBecauseAPhoneKeyboardIsNot() {
        XCTAssertEqual(NamedKey.bytes(for: "ESCAPE"), NamedKey.bytes(for: "escape"))
        XCTAssertEqual(NamedKey.bytes(for: "esc"), NamedKey.bytes(for: "Escape"))
        XCTAssertEqual(NamedKey.bytes(for: "return"), NamedKey.bytes(for: "Enter"))
        XCTAssertEqual(NamedKey.bytes(for: "ctrl-c"), NamedKey.bytes(for: "C-c"))
        XCTAssertEqual(NamedKey.bytes(for: "  Up  "), NamedKey.bytes(for: "Up"))
    }

    func testAnUnknownNameResolvesToNothingRatherThanToItsOwnText() {
        // The whole point of the vocabulary: "Excape" typed into an agent's prompt box
        // is a worse answer than an error.
        XCTAssertNil(NamedKey.bytes(for: "Excape"))
        XCTAssertNil(NamedKey.bytes(for: "C-"))
        XCTAssertNil(NamedKey.bytes(for: "C-cc"))
        XCTAssertNil(NamedKey.bytes(for: "C-1"))
        XCTAssertNil(NamedKey.bytes(for: ""))
    }

    func testABatchIsAllOrNothing() {
        XCTAssertEqual(NamedKey.resolve(["Up", "Up", "Enter"]),
                       .bytes([0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x41, 0x0D]))
        XCTAssertEqual(NamedKey.resolve(["Up", "Nope", "Enter"]), .unknown("Nope"))
    }

    func testTheVocabularyIsTheWholeAdvertisedSurface() {
        let names = NamedKey.names
        XCTAssertEqual(names.count, 9 + 26)
        for expected in ["Enter", "Escape", "Tab", "Backspace", "Space", "Up", "C-a", "C-z"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
    }

    func testNoKeyIsMistakenForThePasteShapedRemoteMessage() {
        // Keys go to the pty raw: nothing about them is a bracketed paste, which is
        // both what makes them keystrokes and what keeps them out of the dead-session
        // revive path (juancode-23m) that a remote reply deliberately triggers.
        for name in NamedKey.names {
            guard let bytes = NamedKey.bytes(for: name) else {
                return XCTFail("\(name) is in `names` but does not resolve")
            }
            XCTAssertNil(bracketedPasteMessage(String(decoding: bytes, as: UTF8.self)), name)
        }
    }

    func testTheCapabilityIsAdvertisedSoAClientCanFeatureDetectIt() {
        XCTAssertTrue(WireProtocol.capabilities.contains("namedKeys"))
    }
}
