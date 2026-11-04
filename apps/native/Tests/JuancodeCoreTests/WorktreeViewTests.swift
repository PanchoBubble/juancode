import Foundation
import Testing
@testable import JuancodeCore

/// The Worktree viewer's scope and memory: which checkout a session inspects, that
/// state is shared per checkout (and only per checkout), survives a relaunch, and
/// that File mode tells the truth about files that are gone or not text.
@Suite struct WorktreeViewTests {
    private func freshDefaults() -> UserDefaults {
        let name = "worktree-view-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func tempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: scope

    @Test func agentWorktreeWinsOverPtyCwdWhichWinsOverRecorded() {
        #expect(WorktreeIdentity.checkout(agentWorktree: "/r/.claude/worktrees/a", liveCwd: "/r/wt/s1",
                                          recorded: "/r") == "/r/.claude/worktrees/a")
        #expect(WorktreeIdentity.checkout(agentWorktree: nil, liveCwd: "/r/wt/s1", recorded: "/r") == "/r/wt/s1")
        #expect(WorktreeIdentity.checkout(agentWorktree: "", liveCwd: nil, recorded: "/r") == "/r")
        #expect(WorktreeIdentity.checkout(agentWorktree: nil, liveCwd: nil, recorded: nil) == nil)
    }

    @Test func spellingsOfOneCheckoutAreOneIdentity() throws {
        let dir = try tempDir()
        let link = dir + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)
        defer { try? FileManager.default.removeItem(atPath: link); try? FileManager.default.removeItem(atPath: dir) }
        let canonical = WorktreeIdentity.canonical(dir)
        #expect(canonical != nil)
        #expect(WorktreeIdentity.canonical(dir + "/") == canonical)
        #expect(WorktreeIdentity.canonical(dir + "/./sub/..") == canonical)
        #expect(WorktreeIdentity.canonical(link) == canonical)
        #expect(WorktreeIdentity.canonical("  ") == nil)
    }

    // MARK: per-checkout state

    @Test func sessionsSharingACheckoutShareItsState() {
        let store = WorktreeViewStore(defaults: freshDefaults())
        store.update("/repo/wt/a") { s in
            s.section = .files
            s.mode = .file
            s.comparison = .main
            s.select("Sources/App.swift")
        }
        // A second session in the same checkout, its path spelled differently.
        let other = store.state("/repo/wt/a/")
        #expect(other.section == .files)
        #expect(other.mode == .file)
        #expect(other.comparison == .main)
        #expect(other.selectedPath == "Sources/App.swift")
    }

    @Test func anotherCheckoutDoesNotSeeTheFileOrComparison() {
        let store = WorktreeViewStore(defaults: freshDefaults())
        store.update("/repo/wt/a") { s in s.select("secret.txt"); s.comparison = .staged; s.scrollLine = 40 }
        let b = store.state("/repo/wt/b")
        #expect(b.selectedPath == nil)
        #expect(b.comparison == .head)
        #expect(b.scrollLine == nil)
        // The main checkout of the same repo is a different checkout too.
        #expect(store.state("/repo").selectedPath == nil)
    }

    @Test func navigationSurvivesARelaunch() {
        let defaults = freshDefaults()
        WorktreeViewStore(defaults: defaults).update("/repo/wt/a") { s in
            s.section = .changes
            s.mode = .diff
            s.comparison = .staged
            s.select("README.md")
            s.scrollLine = 120
        }
        let relaunched = WorktreeViewStore(defaults: defaults).state("/repo/wt/a")
        #expect(relaunched.section == .changes)
        #expect(relaunched.mode == .diff)
        #expect(relaunched.comparison == .staged)
        #expect(relaunched.selectedPath == "README.md")
        #expect(relaunched.scrollLine == 120)
    }

    @Test func switchingFileKeepsModeAndStartsAtTheTop() {
        var s = WorktreeViewState(mode: .file, selectedPath: "a.swift", scrollLine: 300)
        s.select("a.swift")
        #expect(s.scrollLine == 300)
        s.select("b.swift")
        #expect(s.selectedPath == "b.swift")
        #expect(s.mode == .file)
        #expect(s.scrollLine == nil)
    }

    @Test func oldestCheckoutsAreForgottenPastTheLimit() {
        var clock = 0.0
        let store = WorktreeViewStore(defaults: freshDefaults(), now: { clock += 1; return clock })
        for i in 0...WorktreeViewStore.limit {
            store.update("/wt/\(i)") { $0.select("f\(i)") }
        }
        #expect(store.state("/wt/0").selectedPath == nil)
        #expect(store.state("/wt/1").selectedPath == "f1")
        #expect(store.state("/wt/\(WorktreeViewStore.limit)").selectedPath == "f\(WorktreeViewStore.limit)")
    }

    @Test func aSelectionThatLeftChangesMovesToTheFirstRemaining() {
        #expect(worktreeSelection(remembered: "b", listed: ["a", "b"]) == "b")
        #expect(worktreeSelection(remembered: "gone", listed: ["a", "b"]) == "a")
        #expect(worktreeSelection(remembered: "x", listed: []) == nil)
    }

    // MARK: File mode truthfulness

    @Test func fileContentIsTheBytesOnDiskOrSaysWhyNot() {
        #expect(WorktreeFileContent.read("let x = 1\n") == .text("let x = 1\n"))
        #expect(WorktreeFileContent.read("a\u{0}b") == .binary)
        let huge = String(repeating: "x\n", count: WorktreeFileContent.maxLines + 1)
        if case .tooLarge = WorktreeFileContent.read(huge) {} else { Issue.record("expected tooLarge") }
        // The core's own messages (git::read_file).
        #expect(WorktreeFileContent.failure("file is not utf-8 text", status: .modified) == .binary)
        #expect(WorktreeFileContent.failure("could not read file", status: nil) == .missing)
        #expect(WorktreeFileContent.failure("anything", status: .deleted) == .missing)
        // A transport failure is not evidence the file is gone.
        if case .missing = WorktreeFileContent.failure("could not read the core's answer to /api/git/file",
                                                       status: .modified) {
            Issue.record("a decode failure must not read as a deleted file")
        }
        #expect(WorktreeFileContent.failure("path escapes working dir", status: nil)
                == .unavailable("path escapes working dir"))
    }
}
