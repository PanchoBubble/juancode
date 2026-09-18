import Foundation
import JuancodeCore

/// The Swift core's own git plumbing: cutting a session's isolation worktree,
/// adopting one, removing it, and the change rollup that rides the settle edge.
///
/// What is left of what used to be all of `Git.swift`. The working-tree SURFACE —
/// diff, branch state, commit, push, discard, the file and commit listings — moved
/// into the daemon in juancode-52e8.14.5 (`juancoded_core::git`), and the app reaches
/// it through `CoreClient` now. What stays here is the part that is not a surface at
/// all: it is how THIS core keeps the promises it advertises (`isolateWorktree`, and
/// the `changes` rollup on `activity`), and the parent epic's rule is that a Swift
/// implementation of a capability the Swift core still claims is not a fork to delete.
/// It goes when the Swift core goes — juancode-nqpm — and not before.
///
/// Every shell-out goes through `ProcessRunner`, which inherits the environment
/// verbatim: the prime directive.

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
        var lockedReason: String? = nil
        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("branch ") {
                let b = String(line.dropFirst("branch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                branch = stripRefsHeadsPrefix(b)
            } else if line.hasPrefix("locked ") {
                lockedReason = String(line.dropFirst("locked ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !path.isEmpty {
            trees.append(Worktree(path: path, branch: branch, head: head, main: trees.isEmpty,
                                  lockedReason: lockedReason))
        }
    }
    return trees
}

/// The ref a fresh session worktree branches from: the repo's default branch,
/// refreshed from `origin` first, so a new agent starts from what everyone else has
/// rather than from whatever the main checkout happens to have open. Prefers the
/// remote-tracking ref (`origin/main`) and falls back to the local branch when there
/// is no remote or the fetch fails (offline). Nil when the repo has no default branch
/// at all — a fresh repo with one unnamed commit, say — and the caller should then
/// branch off HEAD as before. Never throws.
public func worktreeBaseRef(_ repoCwd: String) async -> String? {
    guard let base = await defaultBaseBranch(repoCwd) else { return nil }
    let short = base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
    let fetched = await refreshBase(repoCwd, short)
    // A local-only `main` can become `origin/main` once the fetch has run.
    if fetched, !base.hasPrefix("origin/"),
       let out = try? await git(repoCwd, ["rev-parse", "--verify", "--quiet", "origin/\(short)"]),
       !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "origin/\(short)"
    }
    return base
}

/// How long a create is willing to wait for the base-branch refresh before it
/// branches off the ref it already has.
///
/// A `git fetch` with nothing to fetch still pays a full SSH handshake to the forge —
/// measured at 1.8-2.3s against github.com, which was two thirds of the entire cost
/// of starting an isolated session and the reason a worktree session felt slower than
/// an ordinary one. The budget is set so a fetch that IS cheap (a local or on-LAN
/// remote) is still waited for, and a handshake to the internet is not.
private let baseFetchBudget: TimeInterval = 0.25

/// How long a completed fetch counts as current for. The case this exists for is a
/// burst: dispatching five agents used to pay the handshake five times, serially,
/// to refresh the same branch.
private let baseFetchTTL: TimeInterval = 60

/// Bring `origin/<branch>` up to date, waiting at most `baseFetchBudget` for it.
///
/// `true` only when the fetch finished, successfully, inside the budget — the one
/// case where the caller may conclude something about refs it did not have before.
/// A fetch still running when the budget expires is deliberately left alone rather
/// than cancelled: it is what makes the NEXT create current, so the freshness this
/// exists for is not lost, it just stops being something a person waits through.
/// Mirrors `refresh_base` in the rust core, budget and TTL included.
private func refreshBase(_ repoCwd: String, _ branch: String) async -> Bool {
    let clock = BaseFetchClock.shared
    if await clock.isCurrent(repoCwd, branch) { return false }
    await clock.start(repoCwd, branch)
    let deadline = Date().addingTimeInterval(baseFetchBudget)
    while Date() < deadline {
        if await clock.isCurrent(repoCwd, branch) { return true }
        await Nap.ms(5)
    }
    return false
}

/// When each repo's base branch was last fetched, and which fetches are still in the
/// air, so a burst of creates in one repo pays for one refresh rather than one each.
private actor BaseFetchClock {
    static let shared = BaseFetchClock()

    private var lastFetched: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func isCurrent(_ repoCwd: String, _ branch: String) -> Bool {
        guard let at = lastFetched[Self.key(repoCwd, branch)] else { return false }
        return Date().timeIntervalSince(at) < baseFetchTTL
    }

    /// Start a refresh unless one is already running for this repo and branch.
    func start(_ repoCwd: String, _ branch: String) {
        let key = Self.key(repoCwd, branch)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached {
            // Best effort: being offline, or having no remote, must not stop a
            // session being isolated — it just means the local ref is the freshest
            // we have.
            let ok = (try? await ProcessRunner.capture(
                "git", ["fetch", "origin", branch], cwd: repoCwd, timeout: 10))?.ok == true
            await BaseFetchClock.shared.settle(key, ok: ok)
        }
    }

    private func settle(_ key: String, ok: Bool) {
        inFlight.remove(key)
        if ok { lastFetched[key] = Date() }
    }

    private static func key(_ repoCwd: String, _ branch: String) -> String {
        "\(repoCwd)\u{0}\(branch)"
    }
}

/// Whether `name` is safe to spell a directory and a branch with.
///
/// The name can arrive over the wire (`create.worktreeName`), and it is pasted into
/// two things that read a path: `<repo>-worktrees/<name>` and `juancode/<name>`. A
/// name carrying a separator or a `..` would put the tree, and the agent in it,
/// somewhere the client never named — so an unsafe one is refused rather than
/// sanitised into a different tree than the one that was asked for. The daemon
/// applies the same rule (`juancoded-core::worktree::safe_name`).
func isUsableWorktreeName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasPrefix(".") else {
        return false
    }
    return name.allSatisfy { c in
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
    }
}

/// Create a fresh linked worktree off the repo containing `repoCwd`, checked out
/// on a new `juancode/<name>` branch, so a session can work the repo in parallel
/// without sharing the main working tree. The worktree lives in a sibling
/// `<repo>-worktrees/<name>` directory (discoverable, doesn't clutter the repo).
/// The new branch starts at the repo's default branch as `origin` has it (see
/// `worktreeBaseRef`), not at the main checkout's HEAD — otherwise an agent
/// dispatched while you happen to be on a feature branch inherits that branch's
/// half-finished work. Throws a clean message if `repoCwd` isn't a git work tree or
/// the repo has no commit yet to branch from.
public func createWorktree(_ repoCwd: String, _ name: String) async throws -> CreatedWorktree {
    guard isUsableWorktreeName(name) else {
        throw GitError("\"\(name)\" is not a usable worktree name: letters, digits, -, _ and . only.")
    }
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
    // `--no-track` so a branch cut from `origin/main` doesn't take main as its
    // upstream — that would aim a later `git push` at main.
    var add = ["worktree", "add", "--no-track", "-b", branch, dir]
    if let base = await worktreeBaseRef(repoCwd) { add.append(base) }
    do {
        _ = try await gitStrict(repoCwd, add)
    } catch {
        throw GitError(gitErr(error, "Failed to create worktree"))
    }
    linkNodeModules(from: root, to: dir)
    return CreatedWorktree(path: dir, branch: branch)
}

/// A worktree created for a branch that already exists (see
/// `createWorktree(_:_:checkingOut:)`).
public struct BranchWorktree: Sendable, Equatable {
    /// Absolute path to the new worktree's root (the session's cwd).
    public let path: String
    /// The branch checked out in it, or nil when git would only give us a detached
    /// HEAD — which happens when that branch is already checked out somewhere else.
    public let branch: String?

    public init(path: String, branch: String?) {
        self.path = path
        self.branch = branch
    }
}

/// Adopt an existing worktree directory, reporting the branch checked out in it
/// (nil on a detached HEAD, matching `createWorktree(_:_:checkingOut:)`). Worktrees
/// outlive the session that made them, so a replacement agent for the same job can
/// stand in the one its predecessor used instead of creating a second copy. Nil
/// when `path` isn't a usable work tree, so callers fall back to creating one.
public func adoptWorktree(_ path: String) async -> BranchWorktree? {
    guard FileManager.default.fileExists(atPath: path),
          let inside = try? await git(path, ["rev-parse", "--is-inside-work-tree"]),
          inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
    let head = (try? await git(path, ["rev-parse", "--abbrev-ref", "HEAD"]))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = (head == nil || head!.isEmpty || head == "HEAD") ? nil : head
    return BranchWorktree(path: path, branch: branch)
}

/// Create a linked worktree off `repoCwd` with an **existing** branch checked out,
/// for working a branch someone else pushed — a PR's head branch (juancode-4bpz).
///
/// Unlike `createWorktree`, which starts a new `juancode/<name>` branch, this one
/// has to cope with a branch that may not be local yet and may already be checked
/// out. In order: fetch it if it's unknown, check it out normally, fall back to
/// tracking `origin/<branch>`, and finally fall back to a **detached** checkout at
/// its head — git allows one worktree per branch, so a branch you already have open
/// elsewhere can only be read from a detached HEAD. `branch` in the result is nil in
/// that last case, so the caller can tell the agent it has no branch to commit onto.
public func createWorktree(_ repoCwd: String, _ name: String,
                           checkingOut branch: String) async throws -> BranchWorktree {
    let root: String
    do {
        let inside = try await git(repoCwd, ["rev-parse", "--is-inside-work-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inside != "true" { throw GitError("not a work tree") }
        root = try await git(repoCwd, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw GitError("Not a git repository — can't isolate this session in a worktree.")
    }
    let rootURL = URL(fileURLWithPath: root)
    let worktreesDir = rootURL.deletingLastPathComponent()
        .appendingPathComponent("\(rootURL.lastPathComponent)-worktrees")
    try? FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
    // A previous tracking run may have left `<name>` behind (worktrees outlive the
    // session that made them), and `git worktree add` refuses an existing directory.
    var dir = worktreesDir.appendingPathComponent(name).path
    var suffix = 2
    while FileManager.default.fileExists(atPath: dir) {
        dir = worktreesDir.appendingPathComponent("\(name)-\(suffix)").path
        suffix += 1
    }
    // A PR branch pushed by someone else may not exist locally at all; fetch before
    // deciding how to check it out. Best-effort — being offline shouldn't stop us
    // making the worktree, the detached fallback still has the local remote-tracking ref.
    let haveLocal = (try? await git(repoCwd, ["rev-parse", "--verify", "--quiet",
                                             "refs/heads/\(branch)"])) != nil
    if !haveLocal { _ = try? await git(repoCwd, ["fetch", "origin", branch]) }

    if haveLocal, (try? await gitStrict(repoCwd, ["worktree", "add", dir, branch])) != nil {
        linkNodeModules(from: root, to: dir)
        return BranchWorktree(path: dir, branch: branch)
    }
    if !haveLocal, (try? await gitStrict(
        repoCwd, ["worktree", "add", "--track", "-b", branch, dir, "origin/\(branch)"])) != nil {
        linkNodeModules(from: root, to: dir)
        return BranchWorktree(path: dir, branch: branch)
    }
    // Already checked out elsewhere (or the branch resolves but can't be attached):
    // detached at whichever ref we can resolve.
    for ref in [branch, "origin/\(branch)"] {
        if (try? await gitStrict(repoCwd, ["worktree", "add", "--detach", dir, ref])) != nil {
            linkNodeModules(from: root, to: dir)
            return BranchWorktree(path: dir, branch: nil)
        }
    }
    throw GitError("Couldn't create a worktree for branch \(branch).")
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
