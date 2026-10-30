import Testing
@testable import JuancodeCore

/// Where ⌘N and the ⌘⇧N provider chooser put a new session, and how the chooser's
/// arrows move through the provider list.
@Suite struct NewSessionTargetTests {
    @Test func worktreeDefaultOnCutsFromTheRepoRoot() {
        let t = NewSessionTarget.cloning(
            provider: .codex, sessionCwd: "/r-worktrees/slot-3", repoRoot: "/r",
            worktreeDefault: { $0 == "/r" })
        #expect(t == NewSessionTarget(provider: .codex, cwd: "/r", isolateWorktree: true))
    }

    @Test func worktreeDefaultOffSharesTheSessionCheckout() {
        let t = NewSessionTarget.cloning(
            provider: .claude, sessionCwd: "/r-worktrees/slot-3", repoRoot: "/r",
            worktreeDefault: { _ in false })
        #expect(t == NewSessionTarget(provider: .claude, cwd: "/r-worktrees/slot-3",
                                      isolateWorktree: false))
    }

    @Test func worktreeDefaultIsLookedUpByRepoRootNotWorktreeDir() {
        var asked: [String] = []
        _ = NewSessionTarget.cloning(
            provider: .claude, sessionCwd: "/r-worktrees/slot-3", repoRoot: "/r",
            worktreeDefault: { asked.append($0); return false })
        #expect(asked == ["/r"])
    }

    @Test func arrowsWrapThroughEveryProvider() {
        let all: [ProviderId] = [.claude, .codex, .opencode]
        #expect(ProviderChoice.step(.claude, by: 1, in: all) == .codex)
        #expect(ProviderChoice.step(.opencode, by: 1, in: all) == .claude)
        #expect(ProviderChoice.step(.claude, by: -1, in: all) == .opencode)
        #expect(ProviderChoice.step(.kimi, by: 1, in: all) == .claude)
        #expect(ProviderChoice.step(.kimi, by: 1, in: []) == .kimi)
    }
}
