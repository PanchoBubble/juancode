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

    func testDetectAgentWorktreeMatchesLockReasonPid() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        _ = try await commitAll(dir, "init")
        // Mirror Claude Code's EnterWorktree: a linked worktree under
        // `.claude/worktrees/` locked with a reason embedding the agent's pid.
        let wtDir = join(join(join(dir, ".claude"), "worktrees"), "fix-thing")
        try runGit(["worktree", "add", "-b", "worktree-fix-thing", wtDir])
        try runGit(["worktree", "lock", "--reason",
                    "claude session fix-thing (pid 4242 start Fri Jul 10 15:36:13 2026)", wtDir])

        let trees = await listWorktrees(dir)
        let locked = trees.first(where: { resolvePath($0.path) == resolvePath(wtDir) })
        XCTAssertNotNil(locked?.lockedReason?.range(of: "pid 4242"))

        let hit = await detectAgentWorktree(dir, childPid: 4242)
        XCTAssertEqual(hit.map(resolvePath), resolvePath(wtDir))
        // A different pid must not match — nor may 4242 match pid 42421 anywhere.
        let miss = await detectAgentWorktree(dir, childPid: 424)
        XCTAssertNil(miss)
    }

    func testDetectAgentWorktreeNilWithoutLockedWorktrees() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        _ = try await commitAll(dir, "init")
        let noTrees = await detectAgentWorktree(dir, childPid: 4242)
        XCTAssertNil(noTrees)

        // An unlocked linked worktree still doesn't match any pid.
        let wt = try await createWorktree(dir, "plainwt")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }
        let unlocked = await detectAgentWorktree(dir, childPid: 4242)
        XCTAssertNil(unlocked)
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

    // MARK: - revert scope guard (pure)

    func testRevertScopeGuardAcceptsInTreePath() {
        XCTAssertEqual(revertScopedRelativePath(root: "/repo", requested: "src/a.txt"), "src/a.txt")
        // A leading ./ normalizes; a request with the root prefix as an absolute path works too.
        XCTAssertEqual(revertScopedRelativePath(root: "/repo", requested: "./src/a.txt"), "src/a.txt")
        XCTAssertEqual(revertScopedRelativePath(root: "/repo", requested: "/repo/src/a.txt"), "src/a.txt")
    }

    func testRevertScopeGuardRefusesUnscopedOrEscaping() {
        // Empty / whitespace → unscoped.
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: ""))
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "   "))
        // The worktree root itself is not a single file — refuse (would be the whole tree).
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "."))
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "/repo"))
        // Traversal out of the tree.
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "../secret"))
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "src/../../secret"))
        // Absolute path outside the tree.
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "/etc/passwd"))
        // A sibling that merely shares a name prefix must not pass the prefix check.
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "/repo-other/a.txt"))
        // Newline / NUL injection.
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "a\nb"))
        XCTAssertNil(revertScopedRelativePath(root: "/repo", requested: "a\0b"))
    }

    // MARK: - single-hunk patch extraction (pure)

    func testSingleHunkPatchExtractsHeaderPlusOneHunk() {
        let patch = """
        diff --git a/f.txt b/f.txt
        index 111..222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,2 @@
        -one
        +ONE
         two
        @@ -10,2 +10,2 @@
        -ten
        +TEN
         eleven
        """
        let first = singleHunkPatch(patch, index: 0)
        XCTAssertNotNil(first)
        XCTAssertTrue(first!.contains("--- a/f.txt"))
        XCTAssertTrue(first!.contains("@@ -1,2 +1,2 @@"))
        XCTAssertTrue(first!.contains("+ONE"))
        XCTAssertFalse(first!.contains("+TEN"))       // second hunk excluded
        XCTAssertTrue(first!.hasSuffix("\n"))
        let second = singleHunkPatch(patch, index: 1)
        XCTAssertTrue(second!.contains("+TEN"))
        XCTAssertFalse(second!.contains("+ONE"))
        // Out of range / negative → nil.
        XCTAssertNil(singleHunkPatch(patch, index: 2))
        XCTAssertNil(singleHunkPatch(patch, index: -1))
        XCTAssertNil(singleHunkPatch("", index: 0))
    }

    // MARK: - revert (real git)

    func testRevertFileRestoresTrackedModification() async throws {
        writeFile(join(dir, "a.txt"), "one\ntwo\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        writeFile(join(dir, "a.txt"), "one\ntwo\nthree\n")   // uncommitted change
        try runGit(["add", "a.txt"])                          // even staged
        let r = try await revertFile(dir, path: "a.txt")
        XCTAssertEqual(r, RevertResult(path: "a.txt", reverted: true))
        let restored = try String(contentsOfFile: join(dir, "a.txt"), encoding: .utf8)
        XCTAssertEqual(restored, "one\ntwo\n")
        // No diff remains for the file.
        let diff = try await getDiff(dir)
        XCTAssertFalse(diff.files.contains { $0.path == "a.txt" })
    }

    func testRevertFileDeletesUntracked() async throws {
        writeFile(join(dir, "seed.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        writeFile(join(dir, "new.txt"), "fresh\n")            // untracked
        let r = try await revertFile(dir, path: "new.txt")
        XCTAssertTrue(r.reverted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: join(dir, "new.txt")))
    }

    func testRevertFileRefusesOutOfTreePath() async throws {
        writeFile(join(dir, "a.txt"), "one\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        do {
            _ = try await revertFile(dir, path: "../escape.txt")
            XCTFail("expected refusal")
        } catch let e as GitError {
            XCTAssertTrue(e.message.lowercased().contains("unscoped") || e.message.lowercased().contains("out-of-tree"))
        }
    }

    func testRevertHunkDiscardsOneHunkKeepsOthers() async throws {
        // Ten lines committed; edit line 1 and line 10 → two separate hunks.
        let base = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        writeFile(join(dir, "f.txt"), base)
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        var lines = (1...10).map { "line\($0)" }
        lines[0] = "LINE1-changed"
        lines[9] = "LINE10-changed"
        writeFile(join(dir, "f.txt"), lines.joined(separator: "\n") + "\n")

        // Sanity: two hunks present.
        let before = try await getDiff(dir)
        let file = try XCTUnwrap(before.files.first { $0.path == "f.txt" })
        XCTAssertEqual(hunkCount(inDiff: file.diff), 2)

        // Revert only the first hunk (line 1) — the line-10 change must survive.
        let r = try await revertHunk(dir, path: "f.txt", hunkIndex: 0)
        XCTAssertTrue(r.reverted)
        let after = try String(contentsOfFile: join(dir, "f.txt"), encoding: .utf8)
        XCTAssertTrue(after.contains("line1\n"))            // restored
        XCTAssertFalse(after.contains("LINE1-changed"))     // first hunk gone
        XCTAssertTrue(after.contains("LINE10-changed"))     // second hunk kept
    }

    func testRevertHunkRefusesUntracked() async throws {
        writeFile(join(dir, "seed.txt"), "x\n")
        try runGit(["add", "-A"])
        try runGit(["commit", "-qm", "init"])
        writeFile(join(dir, "new.txt"), "a\nb\n")            // untracked
        do {
            _ = try await revertHunk(dir, path: "new.txt", hunkIndex: 0)
            XCTFail("expected refusal for untracked file")
        } catch is GitError {
            // expected
        }
    }

    // MARK: - util

    /// `path.resolve` equivalent for comparing worktree paths regardless of symlinks
    /// (macOS temp dirs are under /var → /private/var).
    private func resolvePath(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
}
