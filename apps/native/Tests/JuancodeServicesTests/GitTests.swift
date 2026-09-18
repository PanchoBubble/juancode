import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The Swift core's own worktree plumbing, against a real temp git repo and real
/// `git` (via ProcessRunner).
///
/// What used to be all of `GitTests` — the diff, state, commit, push and discard
/// tests — went with the surface they covered, into `juancoded-core/src/git.rs`
/// (juancode-52e8.14.5). What is left covers what this core still has to do for
/// itself: cut an isolation worktree, adopt one, remove one.
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
        // git init -q; config user.email/name — same setup as TS beforeEach,
        // plus signing off so no commit here reaches for the developer's gpg.
        try? TempGitRepo.initialize(at: dir)
    }

    override func tearDown() {
        rmrf(dir)
        super.tearDown()
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

    // MARK: - createWorktree / removeWorktree

    func testCreateAndRemoveWorktree() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)

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

    /// The name can arrive over the wire (`create.worktreeName`) and is spelled into
    /// both a directory and a branch, so one that is really a path is refused before
    /// git is asked anything. Sanitising it instead would make a tree nobody named.
    func testCreateWorktreeRefusesANameThatIsReallyAPath() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        for name in ["../escape", "a/b", "", "-rf", ".git"] {
            do {
                let wt = try await createWorktree(dir, name)
                rmrf((wt.path as NSString).deletingLastPathComponent)
                XCTFail("\(name) should not name a worktree")
            } catch let e as GitError {
                XCTAssertNotNil(e.message.range(of: "not a usable worktree name"), e.message)
            }
        }
        // The parent directory was never made on the way to those refusals.
        let siblings = (dir as NSString).lastPathComponent + "-worktrees"
        let parent = join((dir as NSString).deletingLastPathComponent, siblings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent))
    }

    /// A session isolated to start new work must branch off the repo's default
    /// branch, not off whatever the main checkout has open — otherwise dispatching an
    /// agent while you sit on a feature branch hands it that branch's half-done work.
    func testCreateWorktreeBranchesFromDefaultBranchNotCheckedOutHead() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try runGit(["branch", "-M", "main"])
        let mainSha = try runGit(["rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Somebody's in-progress branch, checked out in the main tree.
        try runGit(["checkout", "-q", "-b", "feature/wip"])
        writeFile(join(dir, "wip.txt"), "half done\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "wip"], cwd: dir)
        let wipSha = try runGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wt = try await createWorktree(dir, "basemain")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        let at = try runGit(["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(at, mainSha, "the worktree must start at main")
        XCTAssertNotEqual(at, wipSha)
        XCTAssertFalse(FileManager.default.fileExists(atPath: join(wt.path, "wip.txt")))
    }

    /// With a remote, "the default branch" means what origin has now: the base is
    /// fetched first, so a worktree isn't cut from a local `main` that's days behind.
    /// And the new branch must have no upstream — a branch cut from `origin/main` that
    /// tracked it would aim a later push at main.
    func testCreateWorktreeFetchesOriginBeforeBranching() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try runGit(["branch", "-M", "main"])
        let remote = mkdtemp("juancode-remote-")
        defer { rmrf(remote) }
        try TempGitRepo.initializeBare(at: remote)
        try runGit(["remote", "add", "origin", remote])
        try runGit(["push", "-q", "-u", "origin", "main"])

        // Someone else pushes to main; this checkout hasn't fetched it.
        let other = mkdtemp("juancode-clone-")
        defer { rmrf(other) }
        try runGit(["clone", "-q", remote, other], cwd: NSTemporaryDirectory())
        try runGit(["config", "user.email", "test@example.com"], cwd: other)
        try runGit(["config", "user.name", "Test"], cwd: other)
        try runGit(["config", "commit.gpgsign", "false"], cwd: other)
        writeFile(join(other, "theirs.txt"), "landed\n")
        try runGit(["add", "-A"], cwd: other)
        try runGit(["commit", "-qm", "theirs"], cwd: other)
        try runGit(["push", "-q", "origin", "main"], cwd: other)
        let landed = try runGit(["rev-parse", "HEAD"], cwd: other)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stale = try runGit(["rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(landed, stale, "the local main must genuinely be behind")

        let wt = try await createWorktree(dir, "freshbase")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        let at = try runGit(["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(at, landed, "the worktree must start at origin/main, freshly fetched")
        XCTAssertNil(try? runGit(["rev-parse", "--abbrev-ref", "@{u}"], cwd: wt.path),
                     "the session branch must not track origin/main")
    }

    /// The refresh is best effort, and a forge that is slow to answer must not be
    /// something a person waits through. `ext::` runs the command as git's transport,
    /// so this remote takes five seconds to say anything and then fails — no network,
    /// and no dependence on how a machine behaves when a host is unreachable. A
    /// create that finishes long before that is one that branched off the ref it
    /// already had, which is the point.
    func testCreateWorktreeDoesNotWaitOutASlowRemote() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try runGit(["branch", "-M", "main"])
        let remote = mkdtemp("juancode-remote-")
        defer { rmrf(remote) }
        try TempGitRepo.initializeBare(at: remote)
        try runGit(["remote", "add", "origin", remote])
        try runGit(["push", "-q", "-u", "origin", "main"])
        let base = try runGit(["rev-parse", "origin/main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["remote", "set-url", "origin", "ext::sleep 5"])

        let start = Date()
        let wt = try await createWorktree(dir, "slowremote")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }
        let waited = Date().timeIntervalSince(start)

        XCTAssertLessThan(waited, 4, "create waited \(waited)s on a remote that answers in 5s")
        let at = try runGit(["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(at, base, "must start at the origin/main we already had")
    }

    // MARK: - createWorktree(checkingOut:) — the PR-tracker's worktree (juancode-4bpz)

    /// The ordinary case: the PR's branch exists locally and nothing else has it
    /// checked out, so the worktree gets it attached and the agent can just push.
    func testCreateWorktreeChecksOutAnExistingBranch() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try runGit(["branch", "feature/pr-99"])

        let wt = try await createWorktree(dir, "pr-99", checkingOut: "feature/pr-99")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        XCTAssertEqual(wt.branch, "feature/pr-99")
        let trees = await listWorktrees(dir)
        let found = trees.first(where: { resolvePath($0.path) == resolvePath(wt.path) })
        XCTAssertEqual(found?.branch, "feature/pr-99")
    }

    /// One branch, one worktree — git's rule. A PR branch you already have open
    /// elsewhere (commonly your main checkout) must fall back to a detached HEAD at
    /// that branch's head rather than failing the track.
    func testCreateWorktreeFallsBackToDetachedWhenBranchIsCheckedOutElsewhere() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        // Check the branch out in the main worktree, so it is genuinely taken.
        try runGit(["checkout", "-q", "-b", "feature/taken"])
        let head = try runGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let wt = try await createWorktree(dir, "pr-1", checkingOut: "feature/taken")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        XCTAssertNil(wt.branch, "a branch checked out elsewhere can only be detached")
        // Detached, but sitting on exactly that branch's commit.
        let at = try runGit(["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(at, head)
    }

    /// A second track of the same PR (or a leftover directory from an earlier one)
    /// must not collide: `git worktree add` refuses an existing path.
    func testCreateWorktreeAvoidsAnExistingDirectory() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try runGit(["branch", "feature/pr-7"])
        try runGit(["branch", "feature/pr-7-b"])

        let first = try await createWorktree(dir, "pr-7", checkingOut: "feature/pr-7")
        defer { rmrf((first.path as NSString).deletingLastPathComponent) }
        let second = try await createWorktree(dir, "pr-7", checkingOut: "feature/pr-7-b")

        XCTAssertNotEqual(resolvePath(first.path), resolvePath(second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// No such branch anywhere and no remote to fetch it from — a clean GitError, not
    /// a half-made worktree.
    func testCreateWorktreeThrowsForAnUnknownBranch() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)

        do {
            let wt = try await createWorktree(dir, "pr-404", checkingOut: "nope/missing")
            rmrf((wt.path as NSString).deletingLastPathComponent)
            XCTFail("expected a GitError for a branch that doesn't exist")
        } catch let e as GitError {
            XCTAssertTrue(e.message.contains("nope/missing"), e.message)
        }
    }

    /// A new worktree should be runnable without an install: every `node_modules` the
    /// source checkout has — root and per-package — is linked into the same relative
    /// spot, and a package that doesn't exist on the branch is left alone.
    func testCreateWorktreeLinksNodeModules() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        writeFile(join(dir, ".gitignore"), "node_modules\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        let pkg = join(join(dir, "apps"), "oracle")
        try FileManager.default.createDirectory(atPath: join(pkg, "node_modules"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: join(dir, "node_modules"),
                                                withIntermediateDirectories: true)
        writeFile(join(join(dir, "node_modules"), "marker.txt"), "root\n")
        // Tracked, so `apps/oracle` exists in the worktree for its link to land in.
        writeFile(join(pkg, "index.ts"), "export {}\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "pkg"], cwd: dir)

        let wt = try await createWorktree(dir, "deps")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }

        for rel in ["node_modules", "apps/oracle/node_modules"] {
            let link = join(wt.path, rel)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link)
            XCTAssertEqual(resolvePath(target), resolvePath(join(dir, rel)), rel)
        }
        // Resolves through the link to the real contents.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: join(join(wt.path, "node_modules"), "marker.txt")))
    }

    /// Removing a worktree must unlink the `node_modules` symlink, never delete through
    /// it — otherwise tearing down one session wipes the main checkout's dependencies.
    func testRemoveWorktreeLeavesTheSourceNodeModulesIntact() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
        try FileManager.default.createDirectory(atPath: join(dir, "node_modules"),
                                                withIntermediateDirectories: true)
        let marker = join(join(dir, "node_modules"), "marker.txt")
        writeFile(marker, "root\n")

        let wt = try await createWorktree(dir, "depsrm")
        defer { rmrf((wt.path as NSString).deletingLastPathComponent) }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: join(wt.path, "node_modules")))

        try await removeWorktree(wt.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "the source checkout's node_modules must survive")
    }

    func testRemoveWorktreeForceRemovesWithUncommittedChanges() async throws {
        writeFile(join(dir, "a.txt"), "x\n")
        try runGit(["add", "-A"], cwd: dir)
        try runGit(["commit", "-q", "-m", "init"], cwd: dir)
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

    // MARK: - util

    /// `path.resolve` equivalent for comparing worktree paths regardless of symlinks
    /// (macOS temp dirs are under /var → /private/var).
    private func resolvePath(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
}
