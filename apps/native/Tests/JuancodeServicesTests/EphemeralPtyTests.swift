import XCTest
@testable import JuancodeServices

final class EphemeralPtyTests: XCTestCase {
    /// The command is resolved against PATH, so assert on the binary name rather
    /// than the absolute path this machine happens to resolve to.
    private func editorName(_ env: [String: String]) -> String {
        (editorCommand(env: env).cmd as NSString).lastPathComponent
    }

    func testEditorCommandDefaultsToNvim() {
        XCTAssertEqual(editorName([:]), "nvim")
        XCTAssertTrue(editorCommand(env: [:]).args.isEmpty)
    }

    func testEditorCommandSplitsArgs() {
        let (cmd, args) = editorCommand(env: ["VISUAL": "code -w"])
        XCTAssertEqual((cmd as NSString).lastPathComponent, "code")
        XCTAssertEqual(args, ["-w"])
    }

    /// One precedence for every editor path: the documented JUANCODE_EDITOR knob
    /// wins, and $VISUAL/$EDITOR remain the fallbacks under it.
    func testEditorCommandPrecedence() {
        XCTAssertEqual(editorName(["JUANCODE_EDITOR": "vim", "VISUAL": "nano", "EDITOR": "ed"]), "vim")
        XCTAssertEqual(editorName(["VISUAL": "vim", "EDITOR": "nano"]), "vim")
        XCTAssertEqual(editorName(["EDITOR": "nano"]), "nano")
        XCTAssertEqual(editorName([:]), "nvim")
    }

    func testShellCommandDefaultsToZshInteractive() {
        let (cmd, args) = shellCommand(env: [:])
        XCTAssertEqual(cmd, "/bin/zsh")
        XCTAssertEqual(args, ["-i"])
    }

    func testShellCommandHonoursShellEnv() {
        XCTAssertEqual(shellCommand(env: ["SHELL": "/bin/bash"]).cmd, "/bin/bash")
    }

    func testOpenEditorRejectsPathOutsideCwd() {
        let reg = EphemeralPtyRegistry()
        XCTAssertThrowsError(try reg.openEditor(cwd: "/tmp", file: "../etc/passwd", cols: 80, rows: 24)) { err in
            XCTAssertEqual(err as? EphemeralPtyError, .outsideWorkingDir)
        }
    }
}

extension EphemeralPtyError: Equatable {
    public static func == (lhs: EphemeralPtyError, rhs: EphemeralPtyError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
