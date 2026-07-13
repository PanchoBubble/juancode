import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Work-at-risk detection (juancode-rxu). Pure-logic tests for the root
/// collection, classification, and nudge rules, plus one real-git integration
/// test for the probe (temp-repo pattern from `GitTests`).
final class WorkAtRiskTests: XCTestCase {

    // MARK: - collectRoots

    private func wt(_ path: String, main: Bool = false, branch: String? = nil) -> Worktree {
        Worktree(path: path, branch: branch, head: nil, main: main)
    }

    func testCollectRootsDedupesSessionCwdAgainstItsWorktreePath() {
        // A session whose cwd IS its worktree path shouldn't produce two roots.
        let sessions = [WorkAtRiskScan.SessionRef(id: "s1", cwd: "/repo-worktrees/a",
                                                  worktreePath: "/repo-worktrees/a")]
        let roots = WorkAtRiskScan.collectRoots(sessions: sessions, worktreesByRepo: [:])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].path, "/repo-worktrees/a")
        XCTAssertEqual(roots[0].sessionIds, ["s1"])
        XCTAssertFalse(roots[0].sessionIds.isEmpty) // not orphaned
    }

    func testCollectRootsFlagsOrphanedWorktree() {
        // Repo has a linked worktree no session references → orphaned.
        let sessions = [WorkAtRiskScan.SessionRef(id: "s1", cwd: "/repo", worktreePath: nil)]
        let worktrees = ["/repo": [wt("/repo", main: true), wt("/repo-worktrees/gone")]]
        let roots = WorkAtRiskScan.collectRoots(sessions: sessions, worktreesByRepo: worktrees)
        let byPath = Dictionary(uniqueKeysWithValues: roots.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/repo"]?.sessionIds, ["s1"])
        XCTAssertEqual(byPath["/repo-worktrees/gone"]?.sessionIds, [])
        XCTAssertEqual(byPath["/repo-worktrees/gone"]?.repoRoot, "/repo")
    }

    func testCollectRootsNormalizesTrailingSlashAndDotSegments() {
        let sessions = [
            WorkAtRiskScan.SessionRef(id: "s1", cwd: "/repo/", worktreePath: nil),
            WorkAtRiskScan.SessionRef(id: "s2", cwd: "/repo/./", worktreePath: nil),
        ]
        let roots = WorkAtRiskScan.collectRoots(sessions: sessions, worktreesByRepo: [:])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].path, "/repo")
        XCTAssertEqual(Set(roots[0].sessionIds), ["s1", "s2"])
    }

    // MARK: - classify

    private func state(git: Bool = true, branch: String? = "feature", detached: Bool = false,
                       upstream: String? = nil, ahead: Int = 0, dirty: Bool = false) -> GitState {
        GitState(git: git, branch: branch, detached: detached, upstream: upstream,
                 ahead: ahead, behind: 0, dirty: dirty, remote: upstream != nil)
    }

    private func root() -> WorkAtRiskScan.RootRef {
        WorkAtRiskScan.RootRef(path: "/repo", repoRoot: "/repo", sessionIds: ["s1"])
    }

    func testClassifyCleanTreeIsNil() {
        XCTAssertNil(WorkAtRiskScan.classify(
            root(), state: state(upstream: "origin/main", ahead: 0, dirty: false),
            dirtyFiles: 0, aheadOfBase: nil))
    }

    func testClassifyNonGitIsNil() {
        XCTAssertNil(WorkAtRiskScan.classify(
            root(), state: state(git: false), dirtyFiles: 0, aheadOfBase: nil))
    }

    func testClassifyDirtyOnly() {
        let r = WorkAtRiskScan.classify(
            root(), state: state(upstream: "origin/main", ahead: 0, dirty: true),
            dirtyFiles: 3, aheadOfBase: nil)
        XCTAssertEqual(r?.dirtyFiles, 3)
        XCTAssertEqual(r?.ahead, 0)
        XCTAssertEqual(r?.noUpstream, false)
    }

    func testClassifyAheadWithUpstreamTrustsStateAhead() {
        let r = WorkAtRiskScan.classify(
            root(), state: state(upstream: "origin/main", ahead: 2, dirty: false),
            dirtyFiles: 0, aheadOfBase: 999) // aheadOfBase ignored when upstream exists
        XCTAssertEqual(r?.ahead, 2)
        XCTAssertEqual(r?.noUpstream, false)
    }

    func testClassifyNoUpstreamWithZeroAheadOfBaseIsNil() {
        // The false-positive guard: no upstream but no commits beyond base → clean.
        XCTAssertNil(WorkAtRiskScan.classify(
            root(), state: state(upstream: nil, ahead: 500, dirty: false),
            dirtyFiles: 0, aheadOfBase: 0))
    }

    func testClassifyNoUpstreamWithAheadOfBaseIsAtRisk() {
        let r = WorkAtRiskScan.classify(
            root(), state: state(upstream: nil, ahead: 500, dirty: false),
            dirtyFiles: 0, aheadOfBase: 3)
        XCTAssertEqual(r?.ahead, 3) // uses aheadOfBase, not state.ahead
        XCTAssertEqual(r?.noUpstream, true)
    }

    func testClassifyNilAheadOfBaseCountsAsZero() {
        // No base branch resolvable (e.g. no remote at all) → don't flag history.
        XCTAssertNil(WorkAtRiskScan.classify(
            root(), state: state(upstream: nil, ahead: 500, dirty: false),
            dirtyFiles: 0, aheadOfBase: nil))
    }

    func testClassifyNoUpstreamHeadOnRemoteIsNotUnpushed() {
        // The Land Utopia case (juancode-bo0): no upstream, commits beyond base,
        // but HEAD already on a remote branch → not unpushed, so clean tree = nil.
        XCTAssertNil(WorkAtRiskScan.classify(
            root(), state: state(upstream: nil, ahead: 500, dirty: false),
            dirtyFiles: 0, aheadOfBase: 3, headOnRemote: true))
    }

    func testClassifyHeadOnRemoteStillFlagsDirtyTree() {
        // headOnRemote zeroes only the unpushed count; uncommitted files still risk.
        let r = WorkAtRiskScan.classify(
            root(), state: state(upstream: nil, dirty: true),
            dirtyFiles: 2, aheadOfBase: 3, headOnRemote: true)
        XCTAssertEqual(r?.dirtyFiles, 2)
        XCTAssertEqual(r?.ahead, 0)
    }

    func testClassifyCarriesOrphanedFlag() {
        let orphan = WorkAtRiskScan.RootRef(path: "/wt", repoRoot: "/repo", sessionIds: [])
        let r = WorkAtRiskScan.classify(
            orphan, state: state(upstream: "origin/main", dirty: true),
            dirtyFiles: 1, aheadOfBase: nil)
        XCTAssertEqual(r?.orphaned, true)
    }

    // MARK: - nudges

    private func nudge(_ id: String, atRisk: Bool = true, status: SessionStatus = .running,
                       isLive: Bool = true, activity: SessionActivity? = .idle,
                       lastOutputMs: Int = 0) -> WorkAtRiskScan.NudgeInput {
        WorkAtRiskScan.NudgeInput(id: id, atRisk: atRisk, status: status, isLive: isLive,
                                  activity: activity, lastOutputMs: lastOutputMs)
    }

    func testNudgeBelowIdleThresholdIsSuppressed() {
        let n = nudge("s1", lastOutputMs: 9_000)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: []), [])
    }

    func testNudgeAboveIdleThresholdFires() {
        let n = nudge("s1", lastOutputMs: 0)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: []), ["s1"])
    }

    func testNudgeAlreadyNudgedSuppressed() {
        let n = nudge("s1", lastOutputMs: 0)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: ["s1"]), [])
    }

    func testNudgeBusySessionSuppressedEvenWhenSilent() {
        let n = nudge("s1", activity: .busy, lastOutputMs: 0)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: []), [])
    }

    func testNudgeExitedSessionFiresRegardlessOfIdleTime() {
        let n = nudge("s1", status: .exited, isLive: false, activity: nil, lastOutputMs: 9_999)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: []), ["s1"])
    }

    func testNudgeNotAtRiskSuppressed() {
        let n = nudge("s1", atRisk: false, status: .exited, isLive: false)
        XCTAssertEqual(WorkAtRiskScan.nudges([n], nowMs: 10_000, idleMs: 5_000, alreadyNudged: []), [])
    }

    // MARK: - probeWorkAtRisk (real git)

    private func runGit(_ args: [String], cwd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let err = Pipe(); p.standardOutput = Pipe(); p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "git", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func mkdtemp(_ prefix: String) -> String {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)XXXXXX")
        var bytes = template.utf8CString.map { $0 }
        _ = bytes.withUnsafeMutableBufferPointer { Darwin.mkdtemp($0.baseAddress) }
        return String(cString: bytes)
    }

    func testProbeReportsDirtyFileCount() async throws {
        let dir = mkdtemp("juancode-war-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try runGit(["init", "-q"], cwd: dir)
        try runGit(["config", "user.email", "t@e.com"], cwd: dir)
        try runGit(["config", "user.name", "T"], cwd: dir)
        try "one\n".write(toFile: (dir as NSString).appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-qm", "init"], cwd: dir)

        // Clean tree → not dirty.
        let clean = await probeWorkAtRisk(dir)
        XCTAssertEqual(clean?.dirtyFiles, 0)
        XCTAssertTrue(clean?.state.git == true)

        // Modify + add an untracked file → 2 dirty entries.
        try "one\ntwo\n".write(toFile: (dir as NSString).appendingPathComponent("a.txt"),
                               atomically: true, encoding: .utf8)
        try "new\n".write(toFile: (dir as NSString).appendingPathComponent("b.txt"),
                          atomically: true, encoding: .utf8)
        let dirty = await probeWorkAtRisk(dir)
        XCTAssertEqual(dirty?.dirtyFiles, 2)
    }

    func testProbeNoUpstreamButHeadOnRemoteIsNotUnpushed() async throws {
        // A branch pushed to a remote WITHOUT upstream tracking: HEAD is on a
        // remote branch, so nothing is unpushed even though there is no @{u}.
        let remote = mkdtemp("juancode-remote-")
        let dir = mkdtemp("juancode-war2-")
        defer {
            try? FileManager.default.removeItem(atPath: remote)
            try? FileManager.default.removeItem(atPath: dir)
        }
        try runGit(["init", "-q", "--bare"], cwd: remote)
        try runGit(["init", "-q"], cwd: dir)
        try runGit(["config", "user.email", "t@e.com"], cwd: dir)
        try runGit(["config", "user.name", "T"], cwd: dir)
        try runGit(["remote", "add", "origin", remote], cwd: dir)
        try "one\n".write(toFile: (dir as NSString).appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-qm", "init"], cwd: dir)
        // Push HEAD under a remote branch name but do NOT set upstream (no -u).
        try runGit(["push", "-q", "origin", "HEAD:some-remote-branch"], cwd: dir)

        let probed = await probeWorkAtRisk(dir)
        XCTAssertEqual(probed?.headOnRemote, true)
        XCTAssertNil(probed?.state.upstream) // sanity: no upstream configured
        // Clean tree + head-on-remote → not at risk.
        let risk = WorkAtRiskScan.classify(
            root(), state: probed!.state, dirtyFiles: probed!.dirtyFiles,
            aheadOfBase: probed!.aheadOfBase, headOnRemote: probed!.headOnRemote)
        XCTAssertNil(risk)
    }

    func testProbeReturnsNilForNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { try? FileManager.default.removeItem(atPath: plain) }
        let r = await probeWorkAtRisk(plain)
        XCTAssertNil(r)
    }

    func testProbeReturnsNilForMissingDir() async {
        let r = await probeWorkAtRisk("/nonexistent/path/xyz-\(UUID().uuidString)")
        XCTAssertNil(r)
    }
}
