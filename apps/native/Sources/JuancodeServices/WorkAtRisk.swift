import Foundation
import JuancodeCore

/// Work-at-risk detection (juancode-rxu): find folders — session cwds and git
/// worktrees, including orphaned ones whose sessions are gone — holding
/// uncommitted or unpushed work, so forgotten changes get surfaced instead of
/// rotting in a worktree nobody remembers.
///
/// Split like `SessionHealth`: the brittle rules (root collection/dedup, at-risk
/// classification, nudge debounce) are pure statics on `WorkAtRiskScan`, testable
/// without a repo; the one shell-out lives in `probeWorkAtRisk`.

/// One folder holding at-risk work.
public struct WorkAtRisk: Codable, Sendable, Equatable, Identifiable {
    /// Standardized absolute path of the worktree/cwd — the identity key.
    public var path: String
    /// The repo's main worktree path, "" when unknown (cwd not seen in any
    /// worktree listing).
    public var repoRoot: String
    public var branch: String?
    /// Non-empty `git status --porcelain` line count.
    public var dirtyFiles: Int
    /// Unpushed commits: ahead-of-upstream, or ahead-of-base when no upstream.
    public var ahead: Int
    /// The branch has no upstream at all — nothing is pushed, `ahead` counts
    /// commits beyond the inferred base branch.
    public var noUpstream: Bool
    /// No persisted session references this path — the classic forgotten worktree.
    public var orphaned: Bool
    /// Persisted sessions rooted here (cwd or worktreePath), for badge lookups.
    public var sessionIds: [String]

    public var id: String { path }

    public init(path: String, repoRoot: String, branch: String?, dirtyFiles: Int,
                ahead: Int, noUpstream: Bool, orphaned: Bool, sessionIds: [String]) {
        self.path = path; self.repoRoot = repoRoot; self.branch = branch
        self.dirtyFiles = dirtyFiles; self.ahead = ahead; self.noUpstream = noUpstream
        self.orphaned = orphaned; self.sessionIds = sessionIds
    }
}

public enum WorkAtRiskScan {
    /// A folder to probe: its standardized path, the repo main-worktree path it
    /// belongs to ("" when unknown), and the sessions rooted in it.
    public struct RootRef: Sendable, Equatable {
        public var path: String
        public var repoRoot: String
        public var sessionIds: [String]

        public init(path: String, repoRoot: String, sessionIds: [String]) {
            self.path = path; self.repoRoot = repoRoot; self.sessionIds = sessionIds
        }
    }

    /// A session's location, as the scanner needs it.
    public struct SessionRef: Sendable, Equatable {
        public var id: String
        public var cwd: String
        public var worktreePath: String?

        public init(id: String, cwd: String, worktreePath: String?) {
            self.id = id; self.cwd = cwd; self.worktreePath = worktreePath
        }
    }

    /// Normalize a path for identity comparisons: resolve `..`/`.`/trailing
    /// slashes. Deliberately NOT resolving symlinks — probe paths must stay the
    /// paths sessions actually run in (macOS `/tmp` → `/private/tmp` etc. would
    /// break the session↔badge lookup, which uses the session's own cwd string).
    public static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Union of session locations and every listed worktree, deduped by
    /// normalized path. A root with no session referencing it is `orphaned` —
    /// typically a linked worktree whose session was deleted.
    /// `worktreesByRepo` is keyed by the repo's main worktree path.
    public static func collectRoots(
        sessions: [SessionRef], worktreesByRepo: [String: [Worktree]]
    ) -> [RootRef] {
        // Map every known worktree path to its repo root first, so session cwds
        // inside a repo pick up their repoRoot.
        var repoRootByPath: [String: String] = [:]
        for (repoRoot, trees) in worktreesByRepo {
            let root = normalize(repoRoot)
            for t in trees { repoRootByPath[normalize(t.path)] = root }
        }

        var sessionIdsByPath: [String: [String]] = [:]
        var order: [String] = [] // stable output: sessions first, then worktrees
        func addPath(_ raw: String, sessionId: String?) {
            let p = normalize(raw)
            guard !p.isEmpty else { return }
            if sessionIdsByPath[p] == nil {
                sessionIdsByPath[p] = []
                order.append(p)
            }
            if let sessionId, sessionIdsByPath[p]?.contains(sessionId) != true {
                sessionIdsByPath[p]?.append(sessionId)
            }
        }
        for s in sessions {
            addPath(s.cwd, sessionId: s.id)
            if let wt = s.worktreePath { addPath(wt, sessionId: s.id) }
        }
        for (_, trees) in worktreesByRepo.sorted(by: { $0.key < $1.key }) {
            for t in trees { addPath(t.path, sessionId: nil) }
        }

        return order.map { p in
            RootRef(path: p, repoRoot: repoRootByPath[p] ?? "",
                    sessionIds: sessionIdsByPath[p] ?? [])
        }
    }

    /// Classify one probed root; nil when it isn't at risk. `aheadOfBase` is the
    /// no-upstream fallback count (commits beyond the inferred base branch) —
    /// `state.ahead` counts ALL commits when there's no upstream (Git.swift), so
    /// it must not be trusted in that case; nil `aheadOfBase` (no base found,
    /// e.g. a repo with no remote at all) counts as 0 rather than flagging the
    /// whole history as unpushed. `headOnRemote` (only meaningful with no
    /// upstream) says HEAD is already contained in some remote branch — pushed
    /// without upstream tracking, or sharing history with an already-pushed
    /// branch — so nothing is actually unpushed regardless of `aheadOfBase`.
    public static func classify(
        _ root: RootRef, state: GitState, dirtyFiles: Int, aheadOfBase: Int?,
        headOnRemote: Bool = false
    ) -> WorkAtRisk? {
        guard state.git else { return nil }
        let noUpstream = state.upstream == nil && !state.detached
        let ahead: Int
        if state.upstream != nil { ahead = state.ahead }
        else if headOnRemote { ahead = 0 }
        else { ahead = aheadOfBase ?? 0 }
        guard dirtyFiles > 0 || ahead > 0 else { return nil }
        return WorkAtRisk(
            path: root.path, repoRoot: root.repoRoot, branch: state.branch,
            dirtyFiles: dirtyFiles, ahead: ahead, noUpstream: noUpstream,
            orphaned: root.sessionIds.isEmpty, sessionIds: root.sessionIds)
    }

    /// A session's state, as the nudge rule needs it.
    public struct NudgeInput: Sendable, Equatable {
        public var id: String
        /// The session's folder is in the current at-risk set.
        public var atRisk: Bool
        public var status: SessionStatus
        public var isLive: Bool
        /// Live activity; nil for sessions that aren't live.
        public var activity: SessionActivity?
        /// ms-since-epoch of last pty output (live registry `updatedAt`).
        public var lastOutputMs: Int

        public init(id: String, atRisk: Bool, status: SessionStatus, isLive: Bool,
                    activity: SessionActivity?, lastOutputMs: Int) {
            self.id = id; self.atRisk = atRisk; self.status = status
            self.isLive = isLive; self.activity = activity; self.lastOutputMs = lastOutputMs
        }
    }

    /// Which sessions to nudge about at-risk work right now. A session qualifies
    /// once per at-risk episode (`alreadyNudged` carries the memory; the caller
    /// clears an id when its folder leaves the at-risk set or the session goes
    /// busy again) when its work is at risk AND it's either exited/dead or has
    /// sat non-busy with no output for `idleMs`.
    public static func nudges(
        _ inputs: [NudgeInput], nowMs: Int, idleMs: Int, alreadyNudged: Set<String>
    ) -> [String] {
        inputs.compactMap { s in
            guard s.atRisk, !alreadyNudged.contains(s.id) else { return nil }
            if s.status == .exited || !s.isLive { return s.id }
            guard s.activity != .busy, nowMs - s.lastOutputMs >= idleMs else { return nil }
            return s.id
        }
    }
}

/// True when HEAD is contained in at least one remote-tracking branch — i.e.
/// it's already been pushed somewhere, even if this local branch has no upstream
/// configured (pushed without `-u`, or sharing history with a pushed branch).
/// Never throws; false on any error or with no remotes.
func headContainedInAnyRemote(_ path: String) async -> Bool {
    guard let out = try? await git(path, ["branch", "-r", "--contains", "HEAD"]) else { return false }
    return out.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Branch + dirty-count facts for one root, parsed out of a single
/// `git status --porcelain=v2 --branch`.
///
/// `getGitState` answers the same questions with five separate forks
/// (`rev-parse --is-inside-work-tree`, `symbolic-ref`, `remote`, `rev-parse @{u}`,
/// `rev-list --count`) plus a sixth for the dirty list. At-risk probing runs across
/// every watched worktree, so it uses this instead — one fork for all of it
/// (juancode-78c4). `getGitState` is untouched: the Changes-panel CTAs depend on its
/// exact semantics, including the `remote` flag this doesn't report.
struct GitStatusSummary {
    var branch: String?
    var detached: Bool
    var upstream: String?
    var ahead: Int
    var behind: Int
    var dirtyFiles: Int
}

/// Parse `git status --porcelain=v2 --branch` output. Header lines carry the branch
/// facts; every non-header line is one changed path (`1`/`2` tracked, `u` unmerged,
/// `?` untracked), matching what `--porcelain` v1 counted.
func parseGitStatusSummary(_ out: String) -> GitStatusSummary {
    var s = GitStatusSummary(branch: nil, detached: false, upstream: nil,
                             ahead: 0, behind: 0, dirtyFiles: 0)
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
        guard line.hasPrefix("# ") else {
            // "1 ", "2 ", "u ", "? " — one entry per changed/untracked path.
            if let first = line.first, "12u?".contains(first) { s.dirtyFiles += 1 }
            continue
        }
        let parts = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
        guard let key = parts.first else { continue }
        switch key {
        case "branch.head":
            let value = parts.count > 1 ? String(parts[1]) : ""
            // git prints "(detached)" here for a detached HEAD.
            if value == "(detached)" { s.detached = true } else if !value.isEmpty { s.branch = value }
        case "branch.upstream":
            if parts.count > 1 { s.upstream = String(parts[1]) }
        case "branch.ab":
            // "+<ahead> -<behind>"
            for token in parts.dropFirst() {
                guard let sign = token.first, let n = Int(token.dropFirst()) else { continue }
                if sign == "+" { s.ahead = n } else if sign == "-" { s.behind = n }
            }
        default:
            continue
        }
    }
    return s
}

/// Raw git facts about one root, for `WorkAtRiskScan.classify`. nil for a
/// missing dir or non-git cwd. Never throws.
public func probeWorkAtRisk(_ path: String) async -> (state: GitState, dirtyFiles: Int, aheadOfBase: Int?, headOnRemote: Bool)? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    // One fork for branch, upstream, ahead/behind and the dirty count. A non-git dir
    // makes this fail, which is also how we detect it.
    guard let out = try? await git(path, ["status", "--porcelain=v2", "--branch"]) else { return nil }
    let summary = parseGitStatusSummary(out)
    let dirtyFiles = summary.dirtyFiles

    // `remote` is the one `GitState` field this fast path can't know without another
    // fork; `classify` never reads it, so infer it from the upstream rather than pay
    // for `git remote`.
    let state = GitState(
        git: true, branch: summary.branch, detached: summary.detached,
        upstream: summary.upstream,
        // git omits the `branch.ab` header entirely without an upstream, so these stay
        // 0 in that case — which is fine: `classify` distrusts `ahead` when there's no
        // upstream and uses `aheadOfBase` below instead.
        ahead: summary.ahead, behind: summary.behind,
        dirty: dirtyFiles > 0, remote: summary.upstream != nil)

    // With an upstream, `state.ahead` is the true unpushed count. Without one,
    // count commits beyond the inferred base branch instead — `state.ahead`
    // would be the branch's entire history. But first check whether HEAD is
    // already on a remote: a branch pushed without upstream tracking has no
    // `@{u}` yet its commits ARE on the remote, so it isn't unpushed at all.
    var aheadOfBase: Int? = nil
    var headOnRemote = false
    if state.upstream == nil, !state.detached {
        headOnRemote = await headContainedInAnyRemote(path)
        if !headOnRemote, let base = await defaultBaseBranch(path),
           let counted = try? await git(path, ["rev-list", "--count", "\(base)..HEAD"]) {
            aheadOfBase = Int(counted.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    return (state, dirtyFiles, aheadOfBase, headOnRemote)
}
