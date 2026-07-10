import Foundation
import JuancodeCore

/// Git working-tree services for a session's cwd — diff, state, worktrees, and the
/// commit/push write paths. Ported faithfully from `apps/server/src/git.ts`: every
/// shell-out goes through `ProcessRunner` (which inherits the environment verbatim,
/// the prime directive) using a bare `"git"` command resolved via PATH, exactly as
/// the Node `execFile("git", …)` did.

/// Empty-tree object — used as the diff base when a repo has no commits yet.
private let EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

private let MAX_FILES = 300
private let MAX_DIFF_BYTES = 400_000 // per-file cap; larger diffs are summarized, not sent
private let MAX_BUFFER = 64 * 1024 * 1024

/// A freshly created session worktree — its checkout path and the branch on it.
public struct CreatedWorktree: Sendable, Equatable {
    /// Absolute path to the new worktree's root (the session's cwd).
    public let path: String
    /// The new branch checked out in it (`juancode/<name>`).
    public let branch: String

    public init(path: String, branch: String) {
        self.path = path
        self.branch = branch
    }
}

/// A clean, message-bearing error for git failures surfaced to the UI. Mirrors the
/// `new Error(gitErr(...))` the TS throws — the message is the first useful line of
/// git's stderr/stdout (or a supplied fallback).
public struct GitError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Run git, returning stdout. `git diff` exits 1 when differences exist — not an error.
/// Internal so sibling services (WorkAtRisk probe) reuse the same runner semantics.
func git(_ cwd: String, _ args: [String]) async throws -> String {
    // `capture` returns the result for ANY exit code and only throws on
    // launch-failure/timeout, so we inspect the exit code ourselves: exit 1 with
    // stdout means `git diff` "has changes"; any other non-zero is a real error.
    let r = try await ProcessRunner.capture(
        "git", ["-c", "core.quotepath=false"] + args, cwd: cwd, maxBytes: MAX_BUFFER)
    if r.ok { return r.stdout }
    // execFile rejects on non-zero exit; `git diff` uses 1 to signal "has changes".
    if r.exitCode == 1 { return r.stdout }
    throw ProcessError(code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                       launchFailed: false, timedOut: false)
}

/// Run git with no special-casing of exit codes — any non-zero rejects, so write
/// operations (commit/push) surface real failures (hook rejected, no remote, …)
/// instead of being swallowed like a `git diff` "has changes" exit-1. `stdin` feeds
/// a patch to commands that read one (`git apply -`).
private func gitStrict(_ cwd: String, _ args: [String], stdin: String? = nil) async throws -> (stdout: String, stderr: String) {
    let r = try await ProcessRunner.capture(
        "git", ["-c", "core.quotepath=false"] + args, cwd: cwd, stdin: stdin, maxBytes: MAX_BUFFER)
    guard r.ok else {
        throw ProcessError(code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                           launchFailed: false, timedOut: false)
    }
    return (r.stdout, r.stderr)
}

/// First useful line of a git failure (stderr, then stdout), for a clean UI error.
private func gitErr(_ err: Error, _ fallback: String) -> String {
    var stderr = ""
    var stdout = ""
    if let e = err as? ProcessError {
        stderr = e.stderr
        stdout = e.stdout
    }
    let text = "\(stderr)\n\(stdout)".trimmingCharacters(in: .whitespacesAndNewlines)
    let firstUseful = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    return firstUseful ?? fallback
}

private func countChanges(_ diff: String) -> (additions: Int, deletions: Int, binary: Bool) {
    var additions = 0
    var deletions = 0
    for line in diff.components(separatedBy: "\n") {
        // Binary markers appear as unprefixed header lines — guard against matching
        // the same text occurring inside an added/removed (+/-) content line.
        if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            return (0, 0, true)
        }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { additions += 1 }
        else if line.hasPrefix("-") && !line.hasPrefix("---") { deletions += 1 }
    }
    return (additions, deletions, false)
}

private let STATUS_MAP: [String: FileStatus] = ["M": .modified, "A": .added, "D": .deleted]

/// Compute the working-tree diff vs HEAD for a session's cwd: every tracked
/// change (staged + unstaged) plus untracked files, each as its own unified
/// diff. Returns `{ git: false }` for a non-git cwd rather than throwing.
/// Note: like the TS, only the *work-tree confirmation* is guarded — it returns
/// `{ git: false }` for a non-git cwd. After that point an unexpected git failure
/// (a genuine error in a known repo) propagates, so this is `async throws`.
public func getDiff(_ cwd: String) async throws -> DiffResult {
    // Confirm this is a git work tree.
    let root: String
    do {
        let inside = try await git(cwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inside != "true" { return DiffResult(git: false, files: []) }
        root = try await git(cwd, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return DiffResult(git: false, files: [])
    }

    // Diff base: HEAD if it exists, else the empty tree (fresh repo, no commits).
    var base = "HEAD"
    do {
        _ = try await git(cwd, ["rev-parse", "--verify", "HEAD"])
    } catch {
        base = EMPTY_TREE
    }

    return try await collectDiff(cwd, root: root, base: base)
}

/// Result of diffing the current branch against a base branch (juancode-49w):
/// the base ref actually used (e.g. `origin/main`) plus the diff against the
/// merge-base. Carries `base` so the UI can label what it's comparing against.
public struct BaseDiffResult: Sendable, Equatable {
    /// The base ref the diff was computed against (empty when not a git repo).
    public let base: String
    public let result: DiffResult
    public init(base: String, result: DiffResult) {
        self.base = base; self.result = result
    }
}

/// Diff the current branch against its base branch — everything this branch
/// introduced (committed *and* uncommitted) relative to where it diverged from
/// `base`. When `base` is nil the repo's default branch is inferred (origin/HEAD,
/// then main/master/develop). Returns a `{ git: false }` shape for a non-git cwd
/// (mirroring `getDiff`); throws `GitError` when no base branch or no shared
/// history can be found.
public func getBaseDiff(_ cwd: String, base requestedBase: String? = nil) async throws -> BaseDiffResult {
    // Confirm this is a git work tree.
    let root: String
    do {
        let inside = try await git(cwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inside != "true" { return BaseDiffResult(base: "", result: DiffResult(git: false, files: [])) }
        root = try await git(cwd, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return BaseDiffResult(base: "", result: DiffResult(git: false, files: []))
    }

    // Resolve the base ref: the caller's choice, else the inferred default branch.
    let base: String
    if let requestedBase, !requestedBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        base = requestedBase.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let inferred = await defaultBaseBranch(cwd) {
        base = inferred
    } else {
        throw GitError("No base branch found to diff against.")
    }

    // The merge-base is where this branch diverged from `base`; diffing against it
    // shows just this branch's changes (not commits that landed on base since).
    let mergeBase: String
    do {
        mergeBase = try await git(cwd, ["merge-base", base, "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw GitError("No base branch found to diff against.")
    }
    if mergeBase.isEmpty { throw GitError("No common history with \(base).") }

    let result = try await collectDiff(cwd, root: root, base: mergeBase)
    return BaseDiffResult(base: base, result: result)
}

/// Infer the repo's default/base branch: the `origin/HEAD` symbolic ref first
/// (e.g. `origin/main`), then the first of main/master/develop that exists as a
/// remote or local ref. Returns nil when none can be found. Never throws.
public func defaultBaseBranch(_ cwd: String) async -> String? {
    // origin/HEAD points at the remote's default branch when it's been set.
    if let head = try? await git(cwd, ["rev-parse", "--abbrev-ref", "origin/HEAD"]) {
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ref.isEmpty && ref != "origin/HEAD" { return ref }
    }
    for name in ["main", "master", "develop"] {
        for ref in ["origin/\(name)", name] {
            if let out = try? await git(cwd, ["rev-parse", "--verify", "--quiet", ref]),
               !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ref
            }
        }
    }
    return nil
}

/// One commit in the ChangesPanel's commit picker (juancode-5u2), newest first.
public struct RecentCommit: Sendable, Equatable, Identifiable {
    public var id: String { sha }
    public let sha: String         // full %H
    public let shortSha: String    // %h
    public let subject: String     // %s
    public let relativeAge: String // %cr, e.g. "3 hours ago"
    /// Whether the commit is in `<base>..HEAD`, i.e. not on the base branch yet.
    public let aheadOfBase: Bool

    public init(sha: String, shortSha: String, subject: String, relativeAge: String,
                aheadOfBase: Bool) {
        self.sha = sha; self.shortSha = shortSha; self.subject = subject
        self.relativeAge = relativeAge; self.aheadOfBase = aheadOfBase
    }
}

/// Last `limit` commits of HEAD, newest first, with the ones not yet on the base
/// branch marked. Never throws — returns [] for a non-git cwd, an empty repo
/// (no HEAD), or any git failure, so the picker just shows an empty state.
public func listRecentCommits(_ cwd: String, limit: Int = 50) async -> [RecentCommit] {
    guard let inside = try? await git(cwd, ["rev-parse", "--is-inside-work-tree"]),
          inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    else { return [] }

    // Unit-separator field delimiter: subjects can contain tabs/spaces.
    guard let log = try? await git(
        cwd, ["log", "-n", String(limit), "--format=%H%x1f%h%x1f%s%x1f%cr"])
    else { return [] }

    // Commits ahead of the inferred base branch. The --max-count cap is safe: any
    // base..HEAD commit within the first `limit` log entries is also within the
    // first `limit` rev-list entries. Failures just leave every mark false.
    var ahead: Set<String> = []
    if let base = await defaultBaseBranch(cwd),
       let revs = try? await git(cwd, ["rev-list", "--max-count=\(limit)", "\(base)..HEAD"]) {
        ahead = Set(revs.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    return log.split(separator: "\n").compactMap { line in
        let fields = line.components(separatedBy: "\u{1f}")
        guard fields.count >= 4 else { return nil }
        return RecentCommit(sha: fields[0], shortSha: fields[1], subject: fields[2],
                            relativeAge: fields[3], aheadOfBase: ahead.contains(fields[0]))
    }
}

/// The diff a single commit introduced, in the same per-file shape `getDiff`
/// produces (juancode-5u2). Root commits diff against the empty tree; merge
/// commits diff against their FIRST parent (a plain two-point `git diff` — `git
/// show` emits combined `@@@` hunks for merges that `parseMultiFileDiff` can't
/// parse). Returns `{ git: false }` for a non-git cwd; throws `GitError` when the
/// sha doesn't resolve (e.g. rewritten or rebased away).
public func getCommitDiff(_ cwd: String, sha: String) async throws -> DiffResult {
    guard let inside = try? await git(cwd, ["rev-parse", "--is-inside-work-tree"]),
          inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    else { return DiffResult(git: false, files: []) }

    let parents: String
    do {
        parents = try await git(cwd, ["rev-list", "--parents", "-n", "1", sha])
    } catch {
        throw GitError("Commit \(sha.prefix(7)) not found — it may have been rewritten or rebased away.")
    }
    let tokens = parents.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ").map(String.init)
    guard !tokens.isEmpty else {
        throw GitError("Commit \(sha.prefix(7)) not found — it may have been rewritten or rebased away.")
    }
    let parent = tokens.count > 1 ? tokens[1] : EMPTY_TREE

    let patch = try await git(cwd, ["diff", "-M", parent, tokens[0]])
    var files = parseMultiFileDiff(patch)
    let truncatedFiles = files.count > MAX_FILES
    if truncatedFiles { files = Array(files.prefix(MAX_FILES)) }
    files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
    return DiffResult(git: true, root: nil, files: files, truncatedFiles: truncatedFiles)
}

/// Build the per-file diff set of a known git work tree against `base`: every
/// tracked change (name-status, renames via -M) plus untracked files, each as its
/// own unified diff. Shared by the working-tree diff (`getDiff`, base = HEAD) and
/// the base-branch diff (`getBaseDiff`, base = merge-base).
private func collectDiff(_ cwd: String, root: String, base: String) async throws -> DiffResult {
    var files: [DiffFile] = []

    // Tracked changes vs base, via name-status (handles renames with -M).
    let nameStatus = try await git(cwd, ["diff", "--name-status", "-M", base])
    for raw in nameStatus.components(separatedBy: "\n") {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        if files.count >= MAX_FILES { break }
        let parts = raw.components(separatedBy: "\t")
        let code = parts.indices.contains(0) ? parts[0] : ""
        if code.hasPrefix("R"),
           parts.indices.contains(1), !parts[1].isEmpty,
           parts.indices.contains(2), !parts[2].isEmpty {
            let oldPath = parts[1]
            let newPath = parts[2]
            let diff = try await git(cwd, ["diff", "-M", base, "--", oldPath, newPath])
            files.append(buildFile(newPath, oldPath, .renamed, diff))
        } else if parts.indices.contains(1), !parts[1].isEmpty {
            let path = parts[1]
            let firstChar = code.isEmpty ? "" : String(code[code.startIndex])
            let status = STATUS_MAP[firstChar] ?? .modified
            let diff = try await git(cwd, ["diff", base, "--", path])
            files.append(buildFile(path, nil, status, diff))
        }
    }

    // Untracked files — shown as full additions via diff against /dev/null.
    let untracked = try await git(cwd, ["ls-files", "--others", "--exclude-standard"])
    for path in untracked.components(separatedBy: "\n") {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        if files.count >= MAX_FILES { break }
        // --no-index exits 1 when files differ; git() tolerates that.
        let diff = try await git(cwd, ["diff", "--no-index", "--", "/dev/null", path])
        files.append(buildFile(path, nil, .untracked, diff))
    }

    files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
    let truncatedFiles = files.count >= MAX_FILES
    return DiffResult(git: true, root: root, files: files, truncatedFiles: truncatedFiles)
}

/// List the linked worktrees of the repo containing `cwd` (the main worktree is
/// first, flagged `main`). Returns `[]` for a non-git cwd. Parses the stable
/// `--porcelain` format: blank-line-separated blocks of `key value` lines.
public func listWorktrees(_ cwd: String) async -> [Worktree] {
    let out: String
    do {
        out = try await git(cwd, ["worktree", "list", "--porcelain"])
    } catch {
        return []
    }
    var trees: [Worktree] = []
    // TS splits on /\n\s*\n/ — a blank line (possibly with whitespace) between blocks.
    let blockRegex = try? NSRegularExpression(pattern: "\\n\\s*\\n")
    let blocks: [String]
    if let blockRegex {
        blocks = splitByRegex(out, blockRegex)
    } else {
        blocks = [out]
    }
    for block in blocks {
        var path = ""
        var branch: String? = nil
        var head: String? = nil
        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("branch ") {
                let b = String(line.dropFirst("branch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                branch = stripRefsHeadsPrefix(b)
            }
        }
        if !path.isEmpty {
            trees.append(Worktree(path: path, branch: branch, head: head, main: trees.isEmpty))
        }
    }
    return trees
}

/// Create a fresh linked worktree off the repo containing `repoCwd`, checked out
/// on a new `juancode/<name>` branch, so a session can work the repo in parallel
/// without sharing the main working tree. The worktree lives in a sibling
/// `<repo>-worktrees/<name>` directory (discoverable, doesn't clutter the repo).
/// Throws a clean message if `repoCwd` isn't a git work tree or the repo has no
/// commit yet to branch from.
public func createWorktree(_ repoCwd: String, _ name: String) async throws -> CreatedWorktree {
    let root: String
    do {
        let inside = try await git(repoCwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inside != "true" {
            throw GitError("not a work tree")
        }
        root = try await git(repoCwd, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw GitError("Not a git repository — can't isolate this session in a worktree.")
    }
    let branch = "juancode/\(name)"
    // Sibling `<repo>-worktrees/<name>` directory, mirroring TS path.join semantics.
    let rootURL = URL(fileURLWithPath: root)
    let parent = rootURL.deletingLastPathComponent()                 // dirname(root)
    let repoBase = rootURL.lastPathComponent                         // basename(root)
    let worktreesDir = parent.appendingPathComponent("\(repoBase)-worktrees")
    let dirURL = worktreesDir.appendingPathComponent(name)
    let dir = dirURL.path
    // mkdirSync(dirname(dir), { recursive: true }) → create the `<repo>-worktrees` parent.
    try? FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
    do {
        _ = try await gitStrict(repoCwd, ["worktree", "add", "-b", branch, dir])
    } catch {
        throw GitError(gitErr(error, "Failed to create worktree"))
    }
    return CreatedWorktree(path: dir, branch: branch)
}

/// Remove a session-owned worktree (created by `createWorktree`) and its
/// directory. Runs the removal from the repo's main worktree — git refuses to
/// remove the worktree you're standing in — and `--force`s past any uncommitted
/// changes, since the owning session is being deleted. The branch is left intact
/// so committed work survives. Throws if git can't remove it.
public func removeWorktree(_ worktreePath: String) async throws {
    let trees = await listWorktrees(worktreePath)
    let from = trees.first(where: { $0.main })?.path ?? worktreePath
    do {
        _ = try await gitStrict(from, ["worktree", "remove", "--force", worktreePath])
    } catch {
        throw GitError(gitErr(error, "Failed to remove worktree"))
    }
}

/// Working-tree git state for `cwd`: branch, upstream, ahead/behind counts, and
/// whether the tree is dirty — everything the commit/push/PR CTAs need to decide
/// what's actionable. Returns a `{ git: false }` shape (never throws) for a
/// non-git cwd, mirroring `getDiff`.
public func getGitState(_ cwd: String) async -> GitState {
    let none = GitState(git: false, branch: nil, detached: false, upstream: nil,
                        ahead: 0, behind: 0, dirty: false, remote: false)
    do {
        let inside = try await git(cwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inside != "true" { return none }
    } catch {
        return none
    }

    // Branch (fails on a detached HEAD).
    var branch: String? = nil
    var detached = false
    do {
        let b = try await git(cwd, ["symbolic-ref", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        branch = b.isEmpty ? nil : b
    } catch {
        detached = true
    }

    var remote = false
    do {
        remote = try await git(cwd, ["remote"])
            .trimmingCharacters(in: .whitespacesAndNewlines).count > 0
    } catch {
        /* no remotes */
    }

    // Upstream + ahead/behind. With no upstream, treat every local commit as ahead.
    var upstream: String? = nil
    var ahead = 0
    var behind = 0
    do {
        let u = try await git(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        upstream = u.isEmpty ? nil : u
    } catch {
        upstream = nil
    }
    if let upstream {
        do {
            let counts = try await git(cwd, ["rev-list", "--left-right", "--count", "\(upstream)...HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Split on whitespace (TS: /\s+/), parse to ints, default 0.
            let nums = counts.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isWhitespace })
                .map { Int($0) ?? 0 }
            let b = nums.indices.contains(0) ? nums[0] : 0
            let a = nums.indices.contains(1) ? nums[1] : 0
            behind = b
            ahead = a
        } catch {
            /* leave zero */
        }
    } else {
        do {
            let c = try await git(cwd, ["rev-list", "--count", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ahead = Int(c) ?? 0
        } catch {
            /* no commits yet */
        }
    }

    var dirty = false
    do {
        dirty = try await git(cwd, ["status", "--porcelain"])
            .trimmingCharacters(in: .whitespacesAndNewlines).count > 0
    } catch {
        /* leave clean */
    }

    return GitState(git: true, branch: branch, detached: detached, upstream: upstream,
                    ahead: ahead, behind: behind, dirty: dirty, remote: remote)
}

/// Whole-tree change snapshot for `cwd` via `git status --porcelain` — the light
/// model a live file-tree / Quick Open index consumes, refreshed by the worktree
/// watcher. Never throws: returns `[]` for a non-git cwd or any git failure.
public func computeWorktreeStatus(_ cwd: String) async -> [WorktreeStatusEntry] {
    guard let out = try? await git(cwd, ["status", "--porcelain"]) else { return [] }
    return parseWorktreeStatus(out)
}

/// A cheap change summary for `cwd`: the changed-file count + total line
/// additions/deletions vs HEAD, plus a signature of the name-status list for
/// debouncing the review badge. Reuses the porcelain snapshot for the file
/// set/signature and a single `--numstat` for the line totals — no per-file patch
/// generation, so it's fine to run on every settle edge. Line totals cover tracked
/// changes; untracked files still count toward `files`. Empty for a clean or
/// non-git cwd.
public func computeChangeStat(_ cwd: String) async -> ChangeStat {
    let entries = await computeWorktreeStatus(cwd)
    guard !entries.isEmpty else {
        return ChangeStat(files: 0, additions: 0, deletions: 0, signature: "")
    }
    var additions = 0
    var deletions = 0
    if let out = try? await git(cwd, ["diff", "--numstat", "HEAD"]) {
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 2)
            // Binary files report "-\t-"; `Int(...)` yields nil → contributes 0.
            guard cols.count >= 2 else { continue }
            additions += Int(cols[0]) ?? 0
            deletions += Int(cols[1]) ?? 0
        }
    }
    return ChangeStat(files: entries.count, additions: additions, deletions: deletions,
                      signature: changeStatSignature(entries))
}

/// Stage every change (`git add -A`) and commit it with `message`.
public func commitAll(_ cwd: String, _ message: String) async throws -> CommitResult {
    _ = try await gitStrict(cwd, ["add", "-A"])
    let staged = try await gitStrict(cwd, ["diff", "--cached", "--name-only"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if staged.isEmpty {
        throw GitError("Nothing to commit.")
    }
    do {
        _ = try await gitStrict(cwd, ["commit", "-m", message])
    } catch {
        throw GitError(gitErr(error, "Commit failed"))
    }
    let sha = try await gitStrict(cwd, ["rev-parse", "--short", "HEAD"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = try await gitStrict(cwd, ["log", "-1", "--pretty=%s"]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return CommitResult(sha: sha, subject: subject)
}

/// Push the current branch, setting the upstream to origin on first push.
public func pushCurrent(_ cwd: String) async throws -> PushResult {
    // TS: `.catch(() => ({ stdout: "" }))` — a detached HEAD makes symbolic-ref
    // fail, which we swallow into an empty branch string.
    let branch: String
    do {
        branch = try await gitStrict(cwd, ["symbolic-ref", "--short", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        branch = ""
    }
    if branch.isEmpty { throw GitError("Detached HEAD — checkout a branch to push.") }
    var hasUpstream = true
    do {
        _ = try await gitStrict(cwd, ["rev-parse", "--abbrev-ref", "@{upstream}"])
    } catch {
        hasUpstream = false
    }
    let args = hasUpstream ? ["push"] : ["push", "-u", "origin", branch]
    do {
        let (stdout, stderr) = try await gitStrict(cwd, args)
        // git reports a successful push on stderr; fall back to a friendly default.
        let combined = "\(stdout)\(stderr)".trimmingCharacters(in: .whitespacesAndNewlines)
        return PushResult(branch: branch, output: combined.isEmpty ? "Pushed." : combined)
    } catch {
        throw GitError(gitErr(error, "Push failed"))
    }
}

// MARK: - Revert (discard uncommitted work) — precise, guarded, destructive

/// The outcome of a revert: the worktree-relative path acted on, and whether the
/// discard actually ran. Codable so the HTTP route can hand it straight back.
public struct RevertResult: Codable, Sendable, Equatable {
    public let path: String
    public let reverted: Bool
    public init(path: String, reverted: Bool) { self.path = path; self.reverted = reverted }
}

/// Validate that `requested` names a single file STRICTLY inside `root`, returning
/// the worktree-relative path (never empty, never escaping) when safe, else nil.
/// Pure and unit-testable: the revert entry points refuse anything this rejects, so
/// a traversal (`../`), an absolute path outside the tree, an empty/unscoped request,
/// or the worktree root itself can never reach `git checkout` / `git apply`. This is
/// the guard that keeps a destructive discard pinned to exactly one intended file.
public func revertScopedRelativePath(root: String, requested: String) -> String? {
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // No NUL / newline injection into a path passed to git.
    guard !trimmed.contains("\0"), !trimmed.contains("\n") else { return nil }
    let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
    // Join under the worktree root (absolute requests are taken as-is), then collapse
    // `.`/`..` via standardization so the prefix check below sees the real target.
    let joined = trimmed.hasPrefix("/") ? trimmed : rootPath + "/" + trimmed
    let candidate = URL(fileURLWithPath: joined).standardizedFileURL.path
    // Must be strictly inside root: not the root itself (that would be the whole tree),
    // not a sibling/parent, not an escape.
    guard candidate != rootPath, candidate.hasPrefix(rootPath + "/") else { return nil }
    let rel = String(candidate.dropFirst(rootPath.count + 1))
    return rel.isEmpty ? nil : rel
}

/// Confirm `cwd` is inside a git work tree and return its top-level path. Throws a
/// clean `GitError` otherwise — the revert paths refuse to touch a non-repo.
private func worktreeRoot(_ cwd: String) async throws -> String {
    do {
        let inside = try await git(cwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside == "true" else { throw GitError("Not a git repository.") }
        return try await git(cwd, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch let e as GitError {
        throw e
    } catch {
        throw GitError("Not a git repository.")
    }
}

/// Whether `rel` is a tracked path in `cwd` (`ls-files --error-unmatch` exits non-zero
/// for an untracked path, which `gitStrict` surfaces as a throw).
private func isTracked(_ cwd: String, _ rel: String) async -> Bool {
    (try? await gitStrict(cwd, ["ls-files", "--error-unmatch", "--", rel])) != nil
}

/// Discard the uncommitted changes to ONE file, scoped precisely to that path and
/// nothing else. A tracked file is restored from HEAD (`git checkout HEAD -- <path>`,
/// discarding staged and unstaged edits); an untracked file is removed. Refuses any
/// path `revertScopedRelativePath` rejects. Never `git checkout .` / `git reset
/// --hard` — the blast radius is exactly the requested file.
public func revertFile(_ cwd: String, path requested: String) async throws -> RevertResult {
    let root = try await worktreeRoot(cwd)
    guard let rel = revertScopedRelativePath(root: root, requested: requested) else {
        throw GitError("Refusing to revert an unscoped or out-of-tree path.")
    }
    if await isTracked(root, rel) {
        do {
            _ = try await gitStrict(root, ["checkout", "HEAD", "--", rel])
        } catch {
            // A fresh repo has no HEAD to restore from; fall back to the index.
            do { _ = try await gitStrict(root, ["checkout", "--", rel]) }
            catch { throw GitError(gitErr(error, "Revert failed")) }
        }
    } else {
        // Untracked: discarding a brand-new file means deleting it. Still scoped to
        // the one validated path inside the worktree.
        let abs = (root as NSString).appendingPathComponent(rel)
        do { try FileManager.default.removeItem(atPath: abs) }
        catch { throw GitError("Could not remove untracked file: \(rel)") }
    }
    return RevertResult(path: rel, reverted: true)
}

/// Discard ONE hunk of a tracked file's uncommitted change, leaving the rest intact.
/// Re-derives the authoritative current patch (`git diff <base> -- <path>`), extracts
/// exactly the requested hunk, and reverse-applies just that hunk to the working tree
/// (`git apply --reverse`). Refuses an unscoped path or an out-of-range hunk; untracked
/// files aren't supported at hunk granularity (revert the whole file instead).
public func revertHunk(_ cwd: String, path requested: String, hunkIndex: Int) async throws -> RevertResult {
    let root = try await worktreeRoot(cwd)
    guard let rel = revertScopedRelativePath(root: root, requested: requested) else {
        throw GitError("Refusing to revert an unscoped or out-of-tree path.")
    }
    guard hunkIndex >= 0 else { throw GitError("Invalid hunk index.") }
    guard await isTracked(root, rel) else {
        throw GitError("Per-hunk revert isn't supported for untracked files — revert the whole file.")
    }
    var base = "HEAD"
    if (try? await gitStrict(root, ["rev-parse", "--verify", "HEAD"])) == nil { base = EMPTY_TREE }
    let patch = try await git(root, ["diff", base, "--", rel])
    guard let single = singleHunkPatch(patch, index: hunkIndex) else {
        throw GitError("That hunk no longer exists — the file changed since the diff was shown.")
    }
    do {
        _ = try await gitStrict(root, ["apply", "--reverse", "--recount"], stdin: single)
    } catch {
        throw GitError(gitErr(error, "Revert hunk failed"))
    }
    return RevertResult(path: rel, reverted: true)
}

/// Reassemble a single-hunk patch from a one-file unified diff: the file header (every
/// line before the first `@@`) plus the hunk at `index`. Returns nil for an empty patch
/// or an out-of-range index. Pure — unit-tested without git.
public func singleHunkPatch(_ patch: String, index: Int) -> String? {
    guard index >= 0, !patch.isEmpty else { return nil }
    var header: [String] = []
    var hunks: [[String]] = []
    var cur: [String]? = nil
    for line in patch.components(separatedBy: "\n") {
        if line.hasPrefix("@@") {
            if let c = cur { hunks.append(c) }
            cur = [line]
        } else if cur != nil {
            cur?.append(line)
        } else {
            header.append(line)
        }
    }
    if let c = cur { hunks.append(c) }
    guard index < hunks.count else { return nil }
    var out = header
    out.append(contentsOf: hunks[index])
    var joined = out.joined(separator: "\n")
    if !joined.hasSuffix("\n") { joined += "\n" }
    return joined
}

private func buildFile(_ path: String, _ oldPath: String?, _ status: FileStatus, _ diff: String) -> DiffFile {
    let (additions, deletions, binary) = countChanges(diff)
    // TS uses `diff.length` (UTF-16 code units in JS). Use utf16 count to match byte-
    // for-byte the same truncation threshold the web server applies.
    let tooLarge = diff.utf16.count > MAX_DIFF_BYTES
    return DiffFile(
        path: path,
        oldPath: oldPath,
        status: status,
        additions: additions,
        deletions: deletions,
        binary: binary,
        diff: (binary || tooLarge) ? "" : diff,
        truncated: tooLarge)
}

// MARK: - small helpers (regex utilities mirroring TS string ops)

/// Split a string on every match of `regex`, mirroring JS `String.split(regexp)`.
private func splitByRegex(_ s: String, _ regex: NSRegularExpression) -> [String] {
    let ns = s as NSString
    var result: [String] = []
    var last = 0
    let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    for m in matches {
        result.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
        last = m.range.location + m.range.length
    }
    result.append(ns.substring(from: last))
    return result
}

/// `.replace(/^refs\/heads\//, "")` — strip a leading `refs/heads/` if present.
private func stripRefsHeadsPrefix(_ s: String) -> String {
    let prefix = "refs/heads/"
    return s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
}
