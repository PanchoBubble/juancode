import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Ported from `apps/server/src/git.test.ts`. Like the TS, every test stands up a
/// real temp git repo and shells out to real `git` (via ProcessRunner), then makes
/// the same assertions against the ported functions.
final class GitTests: XCTestCase {
    var dir: String = ""

    // MARK: - real-git test helpers

    /// Run `git <args>` in `cwd` (defaults to `dir`), requiring success — mirrors the
    /// TS `execFileSync("git", args, { cwd: dir })`.
    @discardableResult
    private func runGit(_ args: [String], cwd: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd ?? dir)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self)
            ])
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private func mkdtemp(_ prefix: String) -> String {
        let base = NSTemporaryDirectory()
        let template = (base as NSString).appendingPathComponent("\(prefix)XXXXXX")
        var bytes = template.utf8CString.map { $0 } // NUL-terminated mutable buffer
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            Darwin.mkdtemp(buf.baseAddress) != nil
        }
        XCTAssertTrue(ok, "mkdtemp failed")
        return String(cString: bytes)
    }

    private func writeFile(_ path: String, _ contents: String) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func join(_ a: String, _ b: String) -> String {
        (a as NSString).appendingPathComponent(b)
    }

    private func rmrf(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    override func setUp() {
        super.setUp()
        dir = mkdtemp("juancode-git-")
        // git init -q; config user.email/name — same setup as TS beforeEach.
        try? runGit(["init", "-q"])
        try? runGit(["config", "user.email", "test@example.com"])
        try? runGit(["config", "user.name", "Test"])
    }

    override func tearDown() {
        rmrf(dir)
        super.tearDown()
    }

    // MARK: - getDiff

    func testGetDiffReturnsGitFalseForNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        let r = try await getDiff(plain)
        XCTAssertEqual(r, DiffResult(git: false, files: []))
    }

    func testGetDiffReportsModifiedAddedDeleted() async throws {
        writeFile(join(dir, "keep.txt"), "one\ntwo\nthree\n")
        writeFile(join(dir, "gone.txt"), "remove me\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])

        writeFile(join(dir, "keep.txt"), "one\ntwo\nthree\nfour\n") // modified
        writeFile(join(dir, "new.txt"), "fresh\n")                  // untracked
        rmrf(join(dir, "gone.txt"))                                 // deleted

        let r = try await getDiff(dir)
        XCTAssertTrue(r.git)
        var byPath: [String: DiffFile] = [:]
        for f in r.files { byPath[f.path] = f }

        XCTAssertEqual(byPath["keep.txt"]?.status, .modified)
        XCTAssertEqual(byPath["keep.txt"]?.additions, 1)
        XCTAssertEqual(byPath["new.txt"]?.status, .untracked)
        XCTAssertEqual(byPath["new.txt"]?.additions, 1)
        XCTAssertEqual(byPath["gone.txt"]?.status, .deleted)
        XCTAssertEqual(byPath["gone.txt"]?.deletions, 1)
    }

    func testGetDiffDoesNotMisclassifyTextMentioningBinaryMarker() async throws {
        // Regression: binary detection must only inspect unprefixed header lines,
        // not added/removed content that happens to contain the marker string.
        writeFile(join(dir, "talk.txt"), "Binary files differ\nGIT binary patch\nnormal text\n")
        let r = try await getDiff(dir)
        let f = r.files.first(where: { $0.path == "talk.txt" })
        XCTAssertEqual(f?.binary, false)
        XCTAssertEqual(f?.additions, 3)
        XCTAssertGreaterThan(f?.diff.count ?? 0, 0)
    }

    func testGetDiffWorksInFreshRepoNoCommits() async throws {
        writeFile(join(dir, "first.txt"), "hello\n")
        try runGit(["add", "-A"]) // staged but no commit yet — HEAD does not exist

        let r = try await getDiff(dir)
        XCTAssertTrue(r.git)
        let f = r.files.first(where: { $0.path == "first.txt" })
        XCTAssertEqual(f?.additions, 1)
    }

    // MARK: - getBaseDiff (juancode-49w)

    func testGetBaseDiffReturnsGitFalseForNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        let r = try await getBaseDiff(plain, base: nil)
        XCTAssertFalse(r.result.git)
        XCTAssertEqual(r.base, "")
    }

    func testGetBaseDiffShowsOnlyBranchChangesAgainstMergeBase() async throws {
        // main: shared.txt committed. branch feature adds feat.txt; main later moves on.
        writeFile(join(dir, "shared.txt"), "base\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "base"])
        // Capture the default branch name (main or master depending on git config).
        let mainBranch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try runGit(["checkout", "-qb", "feature"])
        writeFile(join(dir, "feat.txt"), "feature work\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "feat"])

        // main advances after the branch diverged — must NOT appear in the base diff.
        try runGit(["checkout", "-q", mainBranch])
        writeFile(join(dir, "shared.txt"), "base changed on main\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "advance main"])
        try runGit(["checkout", "-q", "feature"])

        let r = try await getBaseDiff(dir, base: mainBranch)
        XCTAssertEqual(r.base, mainBranch)
        XCTAssertTrue(r.result.git)
        let paths = Set(r.result.files.map(\.path))
        XCTAssertTrue(paths.contains("feat.txt"), "branch's own change should show")
        XCTAssertFalse(paths.contains("shared.txt"), "post-divergence main change must not show")
    }

    func testGetBaseDiffIncludesUncommittedBranchWork() async throws {
        writeFile(join(dir, "a.txt"), "one\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "base"])
        let mainBranch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "-qb", "feature"])
        // Uncommitted new file on the branch.
        writeFile(join(dir, "scratch.txt"), "wip\n")

        let r = try await getBaseDiff(dir, base: mainBranch)
        XCTAssertTrue(r.result.files.contains(where: { $0.path == "scratch.txt" }))
    }

    func testGetBaseDiffThrowsWhenBaseMissing() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        do {
            _ = try await getBaseDiff(dir, base: "no-such-branch")
            XCTFail("expected throw")
        } catch is GitError {
            // expected — no merge-base with a non-existent ref.
        }
    }

    func testDefaultBaseBranchPrefersLocalMainOrMaster() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        let mainBranch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inferred = await defaultBaseBranch(dir)
        // The single branch (main or master) is the inferred default.
        XCTAssertEqual(inferred, mainBranch)
    }

    // MARK: - getGitState

    func testGetGitStateReturnsGitFalseForNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        let s = await getGitState(plain)
        XCTAssertFalse(s.git)
    }

    func testGetGitStateReportsDirtyTreeNoRemote() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        let s = await getGitState(dir)
        XCTAssertTrue(s.git)
        XCTAssertTrue(s.dirty)
        XCTAssertFalse(s.remote)
        XCTAssertNil(s.upstream)
    }

    func testGetGitStateCleanAndAheadWithNoUpstream() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        let s = await getGitState(dir)
        XCTAssertFalse(s.dirty)
        XCTAssertEqual(s.ahead, 1)
    }

    // MARK: - commitAll

    func testCommitAllStagesEverythingLeavingCleanTree() async throws {
        writeFile(join(dir, "a.txt"), "one\n")
        writeFile(join(dir, "b.txt"), "two\n")
        let r = try await commitAll(dir, "feat: add a and b")
        XCTAssertEqual(r.subject, "feat: add a and b")
        XCTAssertNotNil(r.sha.range(of: "^[0-9a-f]{7,}$", options: .regularExpression))
        let s = await getGitState(dir)
        XCTAssertFalse(s.dirty)
    }

    func testCommitAllRejectsWhenNothingToCommit() async throws {
        writeFile(join(dir, "a.txt"), "one\n")
        _ = try await commitAll(dir, "init")
        do {
            _ = try await commitAll(dir, "again")
            XCTFail("expected throw")
        } catch let e as GitError {
            XCTAssertNotNil(e.message.range(of: "nothing to commit", options: .caseInsensitive))
        }
    }

    // MARK: - createWorktree / removeWorktree

    func testCreateAndRemoveWorktree() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        _ = try await commitAll(dir, "init")

        let wt = try await createWorktree(dir, "abc123de")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        XCTAssertEqual(wt.branch, "juancode/abc123de")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
        // It's a real linked worktree of the same repo, on its own branch.
        let trees = await listWorktrees(dir)
        let found = trees.first(where: { resolvePath($0.path) == resolvePath(wt.path) })
        XCTAssertEqual(found?.branch, "juancode/abc123de")
        XCTAssertEqual(found?.main, false)

        try await removeWorktree(wt.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        let after = await listWorktrees(dir)
        XCTAssertFalse(after.contains(where: { resolvePath($0.path) == resolvePath(wt.path) }))
    }

    func testRemoveWorktreeForceRemovesWithUncommittedChanges() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        _ = try await commitAll(dir, "init")
        let wt = try await createWorktree(dir, "dirtywt")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        writeFile(join(wt.path, "scratch.txt"), "uncommitted\n")
        try await removeWorktree(wt.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    }

    func testCreateWorktreeRejectsNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        do {
            _ = try await createWorktree(plain, "x")
            XCTFail("expected throw")
        } catch let e as GitError {
            XCTAssertNotNil(e.message.range(of: "not a git repository", options: .caseInsensitive))
        }
    }

    // MARK: - pushCurrent

    func testPushCurrentSetsUpstreamOnFirstPush() async throws {
        let remote = mkdtemp("juancode-remote-")
        defer { rmrf(remote) }
        try runGit(["init", "-q", "--bare", remote], cwd: remote)
        try runGit(["remote", "add", "origin", remote])
        writeFile(join(dir, "a.txt"), "one\n")
        _ = try await commitAll(dir, "init")
        let before = await getGitState(dir)
        XCTAssertNil(before.upstream)

        let r = try await pushCurrent(dir)
        XCTAssertFalse(r.branch.isEmpty)

        let after = await getGitState(dir)
        XCTAssertTrue(after.upstream?.contains("origin/") ?? false)
        XCTAssertEqual(after.ahead, 0)
    }

    // MARK: - listRecentCommits (juancode-5u2)

    func testListRecentCommitsNewestFirst() async throws {
        for (i, msg) in ["first", "second", "third"].enumerated() {
            writeFile(join(dir, "f.txt"), "v\(i)\n")
            try runGit(["add", "-A"])
            try runGit(["commit", "-qm", msg])
        }
        let commits = await listRecentCommits(dir)
        XCTAssertEqual(commits.map(\.subject), ["third", "second", "first"])
        for c in commits {
            XCTAssertEqual(c.sha.count, 40)
            XCTAssertTrue(c.sha.hasPrefix(c.shortSha))
            XCTAssertFalse(c.relativeAge.isEmpty)
        }
    }

    func testListRecentCommitsMarksAheadOfBase() async throws {
        writeFile(join(dir, "f.txt"), "base\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "on main"])
        try runGit(["branch", "-M", "main"])
        try runGit(["checkout", "-qb", "feature"])
        for i in 1...2 {
            writeFile(join(dir, "f.txt"), "feature \(i)\n")
            try runGit(["commit", "-aqm", "feature \(i)"])
        }
        let commits = await listRecentCommits(dir)
        XCTAssertEqual(commits.map(\.aheadOfBase), [true, true, false])
    }

    func testListRecentCommitsEmptyForNonGitAndEmptyRepo() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        let nonGit = await listRecentCommits(plain)
        XCTAssertTrue(nonGit.isEmpty)
        // `dir` is a fresh repo with no commits (no HEAD) at this point.
        let emptyRepo = await listRecentCommits(dir)
        XCTAssertTrue(emptyRepo.isEmpty)
    }

    // MARK: - getCommitDiff (juancode-5u2)

    func testGetCommitDiffRootCommit() async throws {
        writeFile(join(dir, "a.txt"), "alpha\nbeta\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "root"])
        let sha = try runGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let r = try await getCommitDiff(dir, sha: sha)
        XCTAssertTrue(r.git)
        XCTAssertEqual(r.files.count, 1)
        XCTAssertEqual(r.files.first?.path, "a.txt")
        XCTAssertEqual(r.files.first?.status, .added)
        XCTAssertEqual(r.files.first?.additions, 2)
    }

    func testGetCommitDiffOrdinaryCommit() async throws {
        writeFile(join(dir, "a.txt"), "one\ntwo\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        writeFile(join(dir, "a.txt"), "one\ntwo\nthree\n")
        try runGit(["commit", "-aqm", "grow"])
        let sha = try runGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Dirty the working tree to prove the diff is the commit's, not the tree's.
        writeFile(join(dir, "a.txt"), "unrelated\n")

        let r = try await getCommitDiff(dir, sha: sha)
        XCTAssertTrue(r.git)
        XCTAssertEqual(r.files.count, 1)
        XCTAssertEqual(r.files.first?.status, .modified)
        XCTAssertEqual(r.files.first?.additions, 1)
        XCTAssertEqual(r.files.first?.deletions, 0)
    }

    func testGetCommitDiffUnknownShaThrowsGitError() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        do {
            _ = try await getCommitDiff(dir, sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
            XCTFail("expected GitError")
        } catch let e as GitError {
            XCTAssertTrue(e.message.contains("deadbee"))
        }
    }

    func testGetCommitDiffNonGitDir() async throws {
        let plain = mkdtemp("juancode-plain-")
        defer { rmrf(plain) }
        let r = try await getCommitDiff(plain, sha: "deadbeef")
        XCTAssertEqual(r, DiffResult(git: false, files: []))
    }

    // MARK: - util

    /// `path.resolve` equivalent for comparing worktree paths regardless of symlinks
    /// (macOS temp dirs are under /var → /private/var).
    private func resolvePath(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
}
