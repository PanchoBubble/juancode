import XCTest
@testable import JuancodeCore

/// Work-at-risk detection (juancode-rxu). The root collection, classification and
/// nudge rules — all of what is left after the git probe moved into the daemon
/// (`juancoded_core::at_risk`, juancode-52e8.14.5), where its own tests live against
/// a real repo.
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
}
