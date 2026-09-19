import XCTest
@testable import JuancodeDesktop

/// Parsers for what `scripts/worktree-sweep.mjs` and
/// `apps/native/scripts/worktree-sweeper-agent.sh` print (juancode-ailq). Pure — no
/// shelling out, no launchd. The fixtures below are verbatim output from the real
/// script run on this machine on 2026-09-19.
final class WorktreeSweeperTests: XCTestCase {

    // MARK: - the sweep's --json

    private let previewJSON = """
    {
      "startedAt": "2026-09-19T21:44:29.945Z",
      "mode": "DRY-RUN",
      "repoRoot": "/Users/x/workdir/personal/juancode",
      "maxAgeDays": 2,
      "daemonReachable": true,
      "daemonChecked": true,
      "processesSampled": true,
      "ghAvailable": true,
      "logFile": "/Users/x/.juancode/logs/worktree-sweep.log",
      "removed": [],
      "rows": [
        {
          "path": "/Users/x/workdir/personal/juancode",
          "branch": "main",
          "head": "e9840f62785f86ba8e25ff1a35248d937d08996f",
          "verdict": "keep",
          "code": "MAIN_CHECKOUT",
          "reason": "the main checkout",
          "ageHours": 0,
          "dirty": 0,
          "aheadMain": 0,
          "pushed": false,
          "removed": false
        },
        {
          "path": "/Users/x/workdir/personal/juancode-worktrees/027e0ce5",
          "branch": "juancode/027e0ce5",
          "head": "a800e0fe190a3583b9d62e0b1a17bfd480e63d4d",
          "verdict": "remove",
          "code": "SPENT",
          "reason": "merged and nothing local",
          "ageHours": 75.5,
          "dirty": 0,
          "aheadMain": 0,
          "pushed": null,
          "removed": false
        }
      ]
    }
    """

    func testDecodesARealDryRun() throws {
        let preview = try WorktreeSweeper.decodePreview(previewJSON)
        XCTAssertEqual(preview.mode, "DRY-RUN")
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.wouldRemove.map(\.code), ["SPENT"])
        XCTAssertEqual(preview.kept.map(\.code), ["MAIN_CHECKOUT"])
        XCTAssertNil(preview.rows[1].pushed)
        XCTAssertTrue(preview.couldRemove)
        XCTAssertNil(preview.blockedReason)
        XCTAssertNil(preview.ghWarning)
    }

    /// The script prints a line of prose before the JSON when run through the agent
    /// wrapper; decoding starts at the first brace so that is not an error.
    func testDecodeSkipsLeadingProse() throws {
        let preview = try WorktreeSweeper.decodePreview("running the sweep now\n" + previewJSON)
        XCTAssertEqual(preview.rows.count, 2)
    }

    func testDecodeRejectsOutputWithNoJSON() {
        XCTAssertThrowsError(try WorktreeSweeper.decodePreview("no node on PATH\n"))
    }

    /// A daemon that will not answer is not "nothing is running", so the pane has to
    /// refuse to arm rather than show a removal list it believes.
    func testUnreachableDaemonBlocksRemoval() throws {
        let json = previewJSON.replacingOccurrences(
            of: "\"daemonReachable\": true", with: "\"daemonReachable\": false")
        let preview = try WorktreeSweeper.decodePreview(json)
        XCTAssertFalse(preview.couldRemove)
        XCTAssertTrue(preview.blockedReason?.contains("no daemon, no sweep") == true)
    }

    func testBlindProcessSampleBlocksRemoval() throws {
        let json = previewJSON.replacingOccurrences(
            of: "\"processesSampled\": true", with: "\"processesSampled\": false")
        let preview = try WorktreeSweeper.decodePreview(json)
        XCTAssertFalse(preview.couldRemove)
        XCTAssertTrue(preview.blockedReason?.contains("lsof/ps") == true)
    }

    func testMissingGhIsReportedButDoesNotBlock() throws {
        let json = previewJSON.replacingOccurrences(
            of: "\"ghAvailable\": true", with: "\"ghAvailable\": false")
        let preview = try WorktreeSweeper.decodePreview(json)
        XCTAssertTrue(preview.couldRemove)
        XCTAssertNotNil(preview.ghWarning)
    }

    func testRowShorteningAndAge() throws {
        let preview = try WorktreeSweeper.decodePreview(previewJSON)
        XCTAssertEqual(preview.rows[0].short, "juancode")
        XCTAssertEqual(preview.rows[1].short, "wt:027e0ce5")
        XCTAssertEqual(preview.rows[1].ageLabel, "3.1d")
        XCTAssertEqual(preview.rows[0].ageLabel, "0m")
    }

    // MARK: - installer status

    func testParsesNotInstalled() {
        let status = WorktreeSweeper.parseStatus("""
        worktree-sweeper: NOT installed (no /Users/x/Library/LaunchAgents/com.juanone.juancode-sweeper.plist)
        worktree-sweeper:   `... install` writes it, disarmed. Nothing prunes worktrees until then.
        worktree-sweeper: not loaded in gui/501
        worktree-sweeper: run log: /Users/x/.juancode/logs/worktree-sweep.log
        """)
        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.armed)
        XCTAssertFalse(status.loaded)
        XCTAssertEqual(status.runLog, "/Users/x/.juancode/logs/worktree-sweep.log")
    }

    func testParsesInstalledDryRun() {
        let status = WorktreeSweeper.parseStatus("""
        worktree-sweeper: installed: /Users/x/Library/LaunchAgents/com.juanone.juancode-sweeper.plist
        worktree-sweeper:   mode:     dry-run
        worktree-sweeper:   checkout: /Users/x/workdir/personal/juancode (this one)
        worktree-sweeper:   days:     7
        worktree-sweeper:   schedule: daily at 4:30, RunAtLoad false
        worktree-sweeper: loaded in gui/501
        worktree-sweeper: run log: /Users/x/.juancode/logs/worktree-sweep.log
        """)
        XCTAssertTrue(status.installed)
        XCTAssertFalse(status.armed)
        XCTAssertTrue(status.loaded)
        XCTAssertEqual(status.days, "7")
        XCTAssertEqual(status.checkout, "/Users/x/workdir/personal/juancode")
        XCTAssertNil(status.otherCheckout)
    }

    func testParsesArmedAndForeignCheckout() {
        let status = WorktreeSweeper.parseStatus("""
        worktree-sweeper: installed: /Users/x/Library/LaunchAgents/com.juanone.juancode-sweeper.plist
        worktree-sweeper:   mode:     ARMED
        worktree-sweeper:   it sweeps ANOTHER CHECKOUT: /Users/x/other (you are in /Users/x/juancode)
        worktree-sweeper:   days:     2
        worktree-sweeper: loaded in gui/501
        """)
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.otherCheckout, "/Users/x/other")
    }

    // MARK: - the run log

    func testParsesTheLastRunOnly() {
        let run = WorktreeSweeper.parseLastRun(log: """
        === 2026-09-19T18:55:38.474Z DRY-RUN root=/tmp/old days=2 trees=2 removed=0 would-remove=1 kept=1
        kept     /tmp/old/a branch=main head=abc age=1h MAIN_CHECKOUT: the main checkout
        === 2026-09-19T20:21:25.560Z APPLY root=/Users/x/juancode days=2 trees=21 removed=2 would-remove=0 kept=19
        REMOVED  /Users/x/juancode-worktrees/aaa branch=juancode/aaa head=abc123 age=3.1d SPENT: merged
        REMOVED  /Users/x/juancode-worktrees/bbb branch=juancode/bbb head=def456 age=4.0d SPENT: merged
        kept     /Users/x/juancode branch=main head=fff age=0h MAIN_CHECKOUT: the main checkout
        """)
        XCTAssertEqual(run?.mode, "APPLY")
        XCTAssertEqual(run?.root, "/Users/x/juancode")
        XCTAssertEqual(run?.trees, 21)
        XCTAssertEqual(run?.removed, 2)
        XCTAssertEqual(run?.kept, 19)
        XCTAssertEqual(run?.days, "2")
        XCTAssertEqual(run?.removedPaths, [
            "/Users/x/juancode-worktrees/aaa",
            "/Users/x/juancode-worktrees/bbb",
        ])
        XCTAssertFalse(run?.daemonUnreachable ?? true)
        XCTAssertNotNil(run?.startedAt)
    }

    /// The mode field can contain spaces, so the header is split on ` root=`.
    func testParsesARefusedRunWithSpacesInItsMode() {
        let run = WorktreeSweeper.parseLastRun(log: """
        === 2026-09-19T20:21:25.560Z REFUSED (daemon unreachable) root=/Users/x/juancode days=2 \
        trees=21 removed=0 would-remove=2 kept=19 daemon=UNREACHABLE
        """)
        XCTAssertEqual(run?.mode, "REFUSED (daemon unreachable)")
        XCTAssertEqual(run?.wouldRemove, 2)
        XCTAssertTrue(run?.daemonUnreachable ?? false)
        XCTAssertEqual(run?.removedPaths, [])
    }

    func testEmptyLogHasNoLastRun() {
        XCTAssertNil(WorktreeSweeper.parseLastRun(log: ""))
        XCTAssertNil(WorktreeSweeper.parseLastRun(log: "nothing here\n"))
    }

    // MARK: - sizes

    func testParsesDuOutput() {
        let sizes = WorktreeSweeper.parseDiskUsage("5570560\t/Users/x/a\n12\t/Users/x/b\n")
        XCTAssertEqual(sizes["/Users/x/a"], 5_570_560 * 1024)
        XCTAssertEqual(sizes["/Users/x/b"], 12 * 1024)
        XCTAssertEqual(sizes.count, 2)
    }

    func testFormatsSizesLikeDuH() {
        XCTAssertEqual(WorktreeSweeper.formatSize(5_570_560 * 1024), "5.3G")
        XCTAssertEqual(WorktreeSweeper.formatSize(12 * 1024 * 1024), "12M")
        XCTAssertEqual(WorktreeSweeper.formatSize(4096), "4K")
        XCTAssertEqual(WorktreeSweeper.formatSize(12), "12B")
    }

    // MARK: - locating the checkout

    private func fakeTree(_ roots: [String]) -> (String) -> Bool {
        { path in
            roots.contains { path == $0 + "/scripts/worktree-sweep.mjs"
                || path == $0 + "/apps/native/scripts/worktree-sweeper-agent.sh" }
        }
    }

    func testFindsTheCheckoutAboveASourceFile() {
        let exists = fakeTree(["/Users/x/juancode"])
        XCTAssertEqual(
            WorktreeSweeper.checkoutAbove("/Users/x/juancode/apps/native/Sources/a.swift", exists: exists),
            "/Users/x/juancode")
        XCTAssertNil(WorktreeSweeper.checkoutAbove("/Users/x/elsewhere/a.swift", exists: exists))
    }

    /// A linked worktree's `.git` is a file. The plist must name the MAIN checkout —
    /// the installer refuses otherwise, because a job pinned to a worktree is pinned
    /// to a directory it is allowed to delete.
    func testResolvesAWorktreeToItsMainCheckout() {
        let exists = fakeTree(["/Users/x/juancode", "/Users/x/juancode-worktrees/18207759"])
        let root = WorktreeSweeper.resolveMainCheckout(
            "/Users/x/juancode-worktrees/18207759",
            exists: { $0 == "/Users/x/juancode-worktrees/18207759/.git" || exists($0) },
            read: { _ in "gitdir: /Users/x/juancode/.git/worktrees/18207759\n" })
        XCTAssertEqual(root, "/Users/x/juancode")
    }

    func testMainCheckoutIsItsOwnMainCheckout() {
        let exists = fakeTree(["/Users/x/juancode"])
        // A main checkout's .git is a directory, so nothing is read from it.
        let root = WorktreeSweeper.resolveMainCheckout(
            "/Users/x/juancode", exists: exists, read: { _ in nil })
        XCTAssertEqual(root, "/Users/x/juancode")
    }

    func testGitFileWithoutAWorktreePathIsIgnored() {
        XCTAssertNil(WorktreeSweeper.mainCheckout(fromGitFile: "gitdir: /Users/x/somewhere/.git\n"))
        XCTAssertNil(WorktreeSweeper.mainCheckout(fromGitFile: "ref: refs/heads/main\n"))
    }

    func testPathsHangOffTheCheckout() {
        let paths = WorktreeSweeperPaths(mainCheckout: "/Users/x/juancode")
        XCTAssertEqual(paths.agentScript,
                       "/Users/x/juancode/apps/native/scripts/worktree-sweeper-agent.sh")
        XCTAssertEqual(paths.sweepScript, "/Users/x/juancode/scripts/worktree-sweep.mjs")
    }

    // MARK: - invocation

    /// `ProcessRunner` inherits the environment verbatim (the prime directive), so an
    /// extra variable has to go through `/usr/bin/env` rather than replace the block.
    func testEnvInvocationPrefixesAssignments() {
        let call = WorktreeSweeper.envInvocation(
            ["JUANCODE_SWEEP_DAYS": "5"], "/bin/bash", ["/s/agent.sh", "install"])
        XCTAssertEqual(call.executable, "/usr/bin/env")
        XCTAssertEqual(call.args, ["JUANCODE_SWEEP_DAYS=5", "/bin/bash", "/s/agent.sh", "install"])
    }

    func testEnvInvocationWithNothingToSetRunsDirectly() {
        let call = WorktreeSweeper.envInvocation([:], "/bin/bash", ["/s/agent.sh", "status"])
        XCTAssertEqual(call.executable, "/bin/bash")
        XCTAssertEqual(call.args, ["/s/agent.sh", "status"])
    }
}
