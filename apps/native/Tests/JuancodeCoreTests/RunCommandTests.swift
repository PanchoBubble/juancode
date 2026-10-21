import Foundation
import Testing
@testable import JuancodeCore

/// The project run command's placeholder expansion: what the play button types
/// into the terminal for a given checkout.
@Suite struct RunCommandTests {
    private let worktree = RunCommand.Context(
        worktree: "/Users/me/luma-core-worktrees/slot-01",
        branch: "juancode/fix-scroll",
        project: "/Users/me/luma-core")

    @Test func fillsEveryPlaceholder() {
        #expect(RunCommand.expand("vr -w {worktree}", worktree)
                == "vr -w /Users/me/luma-core-worktrees/slot-01")
        #expect(RunCommand.expand("echo {branch} {name} {project}", worktree)
                == "echo juancode/fix-scroll slot-01 /Users/me/luma-core")
    }

    @Test func repeatsAndPlainTextAreUntouched() {
        #expect(RunCommand.expand("make vroom", worktree) == "make vroom")
        #expect(RunCommand.expand("{name}-{name}", worktree) == "slot-01-slot-01")
        // Shell brace expansion and unknown tokens pass through.
        #expect(RunCommand.expand("touch {a,b} {nope}", worktree) == "touch {a,b} {nope}")
    }

    @Test func detachedHeadLeavesBranchEmpty() {
        var ctx = worktree
        ctx.branch = nil
        #expect(RunCommand.expand("x{branch}y", ctx) == "xy")
    }

    @Test func readsBranchFromCheckoutAndWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runcmd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("repo")
        let gitDir = main.appendingPathComponent(".git")
        let wtGit = gitDir.appendingPathComponent("worktrees/slot-01")
        let wt = root.appendingPathComponent("repo-worktrees/slot-01")
        for dir in [wtGit, wt] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/juancode/x\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(RunCommand.currentBranch(at: main.path) == "main")
        #expect(RunCommand.currentBranch(at: wt.path) == "juancode/x")
        try "0123abcd\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(RunCommand.currentBranch(at: main.path) == nil)
        #expect(RunCommand.currentBranch(at: root.path) == nil)
    }

    @Test func quotesValuesTheShellWouldSplit() {
        let spaced = RunCommand.Context(worktree: "/Users/me/My Repo", branch: "it's", project: "/p")
        #expect(RunCommand.expand("cd {worktree}", spaced) == "cd '/Users/me/My Repo'")
        #expect(RunCommand.expand("git checkout {branch}", spaced) == "git checkout 'it'\\''s'")
        #expect(RunCommand.expand("{name}", spaced) == "'My Repo'")
    }
}
