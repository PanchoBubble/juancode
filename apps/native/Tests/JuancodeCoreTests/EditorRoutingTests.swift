import XCTest
@testable import JuancodeCore

final class EditorRoutingTests: XCTestCase {
    func testProgramNameIgnoresDirectoryAndFlags() {
        XCTAssertEqual(EditorRouting.programName("/opt/homebrew/bin/nvim"), "nvim")
        XCTAssertEqual(EditorRouting.programName("nvim -u NONE"), "nvim")
        XCTAssertEqual(EditorRouting.programName("code -w"), "code")
    }

    func testALineGoesOnlyToEditorsThatReadPlusN() {
        XCTAssertEqual(EditorRouting.lineArg(command: "/usr/bin/nvim", line: 42), "+42")
        XCTAssertEqual(EditorRouting.lineArg(command: "nano", line: 3), "+3")
        XCTAssertNil(EditorRouting.lineArg(command: "nvim", line: nil))
        XCTAssertNil(EditorRouting.lineArg(command: "nvim", line: 0))
        // `code +42 file` would open a file named `+42`.
        XCTAssertNil(EditorRouting.lineArg(command: "code -w", line: 42))
    }

    func testOnlyVimFamilyEditorsCanBeRetargeted() {
        XCTAssertTrue(EditorRouting.canRetarget(command: "nvim"))
        XCTAssertTrue(EditorRouting.canRetarget(command: "/usr/bin/vim -p"))
        XCTAssertFalse(EditorRouting.canRetarget(command: "hx"))
        XCTAssertFalse(EditorRouting.canRetarget(command: "emacs"))
    }

    func testRetargetKeysReachNormalModeThenDrop() {
        XCTAssertEqual(EditorRouting.retargetKeys(path: "/w/src/a.swift", line: 12),
                       "\u{1c}\u{0e}:drop +12 /w/src/a.swift\r")
        XCTAssertEqual(EditorRouting.retargetKeys(path: "/w/a.swift", line: nil),
                       "\u{1c}\u{0e}:drop /w/a.swift\r")
    }

    /// A space or `%` unescaped would open two files, or the current one.
    func testRetargetKeysEscapeWhatTheCommandLineWouldRead() {
        XCTAssertEqual(EditorRouting.retargetKeys(path: "/w/my file%#|.txt", line: nil),
                       "\u{1c}\u{0e}:drop /w/my\\ file\\%\\#\\|.txt\r")
    }

    func testRetargetKeysRefuseWhatTheyCannotCarry() {
        XCTAssertNil(EditorRouting.retargetKeys(path: "relative.txt", line: nil))
        XCTAssertNil(EditorRouting.retargetKeys(path: "/w/a\nb", line: nil))
    }

    func testConfinedResolvesInsideAndRefusesOutside() {
        XCTAssertEqual(EditorRouting.confined("src/a.swift", to: "/w/repo"), "/w/repo/src/a.swift")
        XCTAssertEqual(EditorRouting.confined("/w/repo/a", to: "/w/repo/"), "/w/repo/a")
        XCTAssertNil(EditorRouting.confined("../etc/passwd", to: "/w/repo"))
        XCTAssertNil(EditorRouting.confined("/w/repo-other/x", to: "/w/repo"))
    }
}
