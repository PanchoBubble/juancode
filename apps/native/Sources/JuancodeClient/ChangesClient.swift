import Foundation
import JuancodeCore

/// The git working tree, as the app asks a core about it.
///
/// Everything here used to be a function call into `JuancodeServices/Git.swift`,
/// which meant the answer only existed in the process the panel was drawn in. It is
/// on `CoreClient` now for the same reason the reaper and the heavy queue are: the
/// tree belongs to whatever holds the session, and the desktop is not always that
/// (juancode-52e8.14.5).
///
/// Every member is `async throws`, and the default for all of them is to throw
/// `CoreCapabilityError(.changes)`. That is deliberate, and it is the heavy queue's
/// precedent: a core that does not advertise `changes` has nothing to fall back on —
/// there is no second implementation to reach for once the Swift service is gone — so
/// the panel reads `unavailableReason(.changes)` and greys itself out with that
/// sentence rather than calling something that would answer a made-up empty diff.
public extension CoreClient {

    // MARK: - Reads

    /// The working-tree diff vs HEAD for `cwd`.
    func diff(cwd: String) async throws -> DiffResult { throw changesUnsupported }

    /// Everything the branch in `cwd` introduced relative to `base`, or to its own
    /// inferred base branch when `base` is nil.
    func baseDiff(cwd: String, base: String?) async throws -> BaseDiffResult {
        throw changesUnsupported
    }

    /// The diff one commit introduced, in the same per-file shape `diff` produces.
    func commitDiff(cwd: String, sha: String) async throws -> DiffResult {
        throw changesUnsupported
    }

    /// Branch, upstream, ahead/behind and dirtiness for `cwd`.
    func gitState(cwd: String) async throws -> GitState { throw changesUnsupported }

    /// The last `limit` commits of HEAD, newest first.
    func recentCommits(cwd: String, limit: Int) async throws -> [RecentCommit] {
        throw changesUnsupported
    }

    /// Every linked worktree of the repo `cwd` belongs to, main one first.
    func worktrees(cwd: String) async throws -> [Worktree] { throw changesUnsupported }

    /// Remove the linked worktree at `path`, and its directory. The branch is left
    /// alone, so committed work survives. A tree that is already gone is a success:
    /// the caller's two states are "there" and "not there", and a sweep over a stale
    /// listing must not report a leak it did not cause. The repo's MAIN worktree is
    /// refused — it is the checkout somebody works in.
    func removeWorktree(path: String) async throws { throw changesUnsupported }

    /// The whole-tree `git status --porcelain` snapshot the file tree consumes.
    func worktreeStatus(cwd: String) async throws -> [WorktreeStatusEntry] {
        throw changesUnsupported
    }

    /// The Quick Open index: tracked plus untracked-but-not-ignored paths.
    func trackedFiles(cwd: String, limit: Int) async throws -> [String] {
        throw changesUnsupported
    }

    /// The cheap files/+/− rollup the review badge shows.
    func changeStat(cwd: String) async throws -> ChangeStat { throw changesUnsupported }

    /// One file's contents, read relative to `cwd` and refused if it escapes.
    func readFile(cwd: String, path: String) async throws -> String {
        throw changesUnsupported
    }

    /// The raw at-risk facts for one folder, for `WorkAtRiskScan.classify` to judge.
    /// Nil for a folder that is missing or is not a work tree — which is a different
    /// answer from "nothing at risk here", and the badge draws neither the same way.
    func probeAtRisk(path: String) async throws -> AtRiskProbe? { throw changesUnsupported }

    /// The worktree the agent process `childPid` cut for itself from inside its pty
    /// (juancode-0sw), matched on the pid it locked the tree with.
    ///
    /// The caller must NOT write this into `SessionMeta.worktreePath`: that field is
    /// what the session-delete reap removes, and a tree the agent manages is not ours
    /// to remove.
    func agentWorktree(cwd: String, childPid: Int32) async throws -> String? {
        throw changesUnsupported
    }

    // MARK: - Writes

    /// Stage everything in `cwd` and commit it.
    func commitAll(sessionId: String, cwd: String?, message: String) async throws -> CommitResult {
        throw changesUnsupported
    }

    /// Push the branch checked out in `cwd`, setting the upstream on the first push.
    func push(sessionId: String, cwd: String?) async throws -> PushResult {
        throw changesUnsupported
    }

    /// Discard uncommitted work: one file, or one hunk of it when `hunkIndex` is set.
    func revert(sessionId: String, cwd: String?, path: String,
                hunkIndex: Int?) async throws -> RevertResult {
        throw changesUnsupported
    }

    /// Draft a commit message for what is currently uncommitted in `cwd`.
    func draftCommitMessage(sessionId: String, cwd: String?) async throws -> String {
        throw changesUnsupported
    }

    /// One spelling of "this core has no working tree to answer about", so a greyed
    /// button and the Settings capability list cannot disagree.
    private var changesUnsupported: any Error {
        CoreCapabilityError(.changes, backend: info.daemon == nil ? "swift" : "rust")
    }
}

/// What a core's at-risk probe found for one folder.
///
/// The two ahead-counts are kept apart on purpose. `state.ahead` counts a branch's
/// ENTIRE history when there is no upstream, which is not "unpushed"; `aheadOfBase`
/// is the count that means it. `headOnRemote` overrides both — a branch pushed
/// without `-u` has no upstream and nothing unpushed. `WorkAtRiskScan.classify`
/// is the one place that resolves the three.
public struct AtRiskProbe: Sendable, Equatable, Codable {
    public var state: GitState
    public var dirtyFiles: Int
    public var aheadOfBase: Int?
    public var headOnRemote: Bool

    public init(state: GitState, dirtyFiles: Int, aheadOfBase: Int?, headOnRemote: Bool) {
        self.state = state
        self.dirtyFiles = dirtyFiles
        self.aheadOfBase = aheadOfBase
        self.headOnRemote = headOnRemote
    }
}
