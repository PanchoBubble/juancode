import XCTest
@testable import JuancodeCore

/// The decision and merge rules of the login-shell environment import (juancode-aw7r).
///
/// No test here runs the probe or asserts on a real environment value: the imported
/// environment is the user's API keys, so the fixtures are deliberately fake names
/// with placeholder values.
final class LoginEnvironmentTests: XCTestCase {

    // MARK: - detection

    /// The measured shape of a Finder/Dock launch on macOS: no tty on any stdio, and
    /// launchd's session environment, which has no SHLVL and a four-entry PATH.
    private let launchdEnv = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/Users/someone", "USER": "someone", "LOGNAME": "someone",
        "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/xx/T/",
        "XPC_SERVICE_NAME": "application.com.juanone.juancode",
        "COMMAND_MODE": "unix2003", "__CFBundleIdentifier": "com.juanone.juancode",
    ]

    func testAFinderLaunchNeedsTheImport() {
        XCTAssertTrue(LoginEnvironment.needsImport(env: launchdEnv, hasTTY: false))
    }

    func testATerminalLaunchDoesNot() {
        var env = launchdEnv
        env["SHLVL"] = "1"
        XCTAssertFalse(LoginEnvironment.needsImport(env: env, hasTTY: true))
    }

    /// `open -a` from a terminal was measured to propagate the caller's whole
    /// environment: no tty, but a shell's SHLVL and the user's real PATH. Importing
    /// there would be pointless work, so SHLVL alone has to be able to veto.
    func testOpenDashAFromATerminalDoesNotNeedTheImport() {
        var env = launchdEnv
        env["SHLVL"] = "3"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
        XCTAssertFalse(LoginEnvironment.needsImport(env: env, hasTTY: false))
    }

    /// `juancode >log 2>&1 &` from a shell: stdio redirected to a file, so no tty,
    /// but the environment is already the terminal's.
    func testARedirectedTerminalLaunchDoesNotNeedTheImport() {
        var env = launchdEnv
        env["SHLVL"] = "2"
        XCTAssertFalse(LoginEnvironment.needsImport(env: env, hasTTY: false))
    }

    func testTheOverrideForcesBothWays() {
        var forceOff = launchdEnv
        forceOff["JUANCODE_LOGIN_ENV"] = "0"
        XCTAssertFalse(LoginEnvironment.needsImport(env: forceOff, hasTTY: false))

        var forceOn = launchdEnv
        forceOn["SHLVL"] = "1"
        forceOn["JUANCODE_LOGIN_ENV"] = "1"
        XCTAssertTrue(LoginEnvironment.needsImport(env: forceOn, hasTTY: true))
    }

    // MARK: - precedence

    /// The rule that protects a value this process was deliberately given.
    func testAnInheritedValueIsNeverOverwritten() {
        let plan = LoginEnvironment.plannedMerge(
            current: ["TMPDIR": "/var/folders/launchd/T/", "JUANCODE_CORE": "swift"],
            login: ["TMPDIR": "/tmp/", "JUANCODE_CORE": "rust", "FAKE_TOKEN": "x"]
        )
        XCTAssertNil(plan["TMPDIR"], "launchd's per-app TMPDIR must survive the import")
        XCTAssertNil(plan["JUANCODE_CORE"], "an explicit override must beat the shell's")
        XCTAssertEqual(plan["FAKE_TOKEN"], "x", "a variable we did not have is what the import is for")
    }

    func testAMissingVariableIsImported() {
        let plan = LoginEnvironment.plannedMerge(
            current: launchdEnv,
            login: ["FAKE_API_KEY": "placeholder", "PNPM_HOME": "/Users/someone/Library/pnpm"]
        )
        XCTAssertEqual(plan["FAKE_API_KEY"], "placeholder")
        XCTAssertEqual(plan["PNPM_HOME"], "/Users/someone/Library/pnpm")
    }

    /// PATH is the one variable launchd *does* set, to a stub — so "only what is
    /// missing" would leave the headline symptom in place.
    func testPathIsMergedNotLeftAlone() {
        let plan = LoginEnvironment.plannedMerge(
            current: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            login: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )
        XCTAssertEqual(plan["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// Login-shell order first (so a Homebrew binary shadows the system one exactly as
    /// it does in the user's terminal), and nothing we already had is dropped.
    func testMergedPathKeepsLoginOrderAndLosesNothing() {
        let merged = LoginEnvironment.mergedPath(
            current: "/usr/bin:/bin:/only/ours",
            login: "/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertEqual(merged, "/opt/homebrew/bin:/usr/bin:/bin:/only/ours")
    }

    func testMergedPathDropsDuplicatesAndEmptyEntries() {
        let merged = LoginEnvironment.mergedPath(current: "/usr/bin::/usr/bin", login: "/usr/bin:/bin")
        XCTAssertEqual(merged, "/usr/bin:/bin")
    }

    func testPathIsNotRewrittenWhenTheMergeChangesNothing() {
        let plan = LoginEnvironment.plannedMerge(
            current: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            login: ["PATH": "/opt/homebrew/bin:/usr/bin"]
        )
        XCTAssertNil(plan["PATH"])
    }

    /// Shell and terminal bookkeeping describes the probe, not the user's setup.
    /// Importing SHLVL in particular would corrupt the next `needsImport` decision.
    func testShellAndTerminalBookkeepingIsNeverImported() {
        let plan = LoginEnvironment.plannedMerge(
            current: [:],
            login: ["SHLVL": "1", "PWD": "/Users/someone", "OLDPWD": "/", "_": "/usr/bin/env",
                    "TERM": "dumb", "COLORTERM": "", "GPG_TTY": "/dev/ttys004",
                    "TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3",
                    "KEEP_ME": "yes"]
        )
        XCTAssertEqual(plan, ["KEEP_ME": "yes"])
    }

    // MARK: - parsing

    func testParsingSkipsRcChatterBeforeTheMarker() {
        let raw = "Welcome back!\nnvm: using v24\n\(LoginEnvironment.marker)\u{0}PATH=/bin\u{0}A=1\u{0}"
        let parsed = LoginEnvironment.parseProbeOutput(Data(raw.utf8))
        XCTAssertEqual(parsed, ["PATH": "/bin", "A": "1"])
    }

    func testAValueContainingAnEqualsSignSurvives() {
        let raw = "\(LoginEnvironment.marker)\u{0}LS_COLORS=di=34:ln=35\u{0}"
        XCTAssertEqual(LoginEnvironment.parseProbeOutput(Data(raw.utf8))?["LS_COLORS"], "di=34:ln=35")
    }

    func testAMultilineValueSurvives() {
        let raw = "\(LoginEnvironment.marker)\u{0}FAKE_PEM=line1\nline2\u{0}A=1\u{0}"
        XCTAssertEqual(LoginEnvironment.parseProbeOutput(Data(raw.utf8))?["FAKE_PEM"], "line1\nline2")
    }

    /// No marker means the shell died before it reached `env` — a partial parse of
    /// whatever it printed would be worse than importing nothing.
    func testNoMarkerIsAFailureNotAPartialParse() {
        XCTAssertNil(LoginEnvironment.parseProbeOutput(Data("PATH=/bin\u{0}".utf8)))
        XCTAssertNil(LoginEnvironment.parseProbeOutput(Data()))
    }

    func testFieldsWithoutANameAreIgnored() {
        let raw = "\(LoginEnvironment.marker)\u{0}=novalue\u{0}noequals\u{0}A=1\u{0}"
        XCTAssertEqual(LoginEnvironment.parseProbeOutput(Data(raw.utf8)), ["A": "1"])
    }

    // MARK: - barrier

    /// The barrier must not hang a spawn when no import was ever started, which is
    /// every unit test (nothing calls `importAtLaunch`) and every terminal launch.
    /// Without the `.idle` short-circuit this waits the full budget on every spawn.
    func testTheBarrierReturnsImmediatelyWhenNoImportWasStarted() {
        XCTAssertEqual(LoginEnvironment.status, .pending)
        let started = Date()
        LoginEnvironment.waitUntilReady(timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "an idle import must not make the spawn path wait")
    }
}
