import Foundation

/// Where a keyboard-created session lands when it clones the selected one: ⌘N
/// (same agent) and the ⌘⇧N provider chooser (the agent you pick). Split out from
/// `AppModel` so the folder + worktree resolution both gestures share is testable
/// without spawning ptys or touching git.
public struct NewSessionTarget: Equatable, Sendable {
    public var provider: ProviderId
    public var cwd: String
    public var isolateWorktree: Bool

    public init(provider: ProviderId, cwd: String, isolateWorktree: Bool) {
        self.provider = provider
        self.cwd = cwd
        self.isolateWorktree = isolateWorktree
    }

    /// Clone a session's project. `sessionCwd` is where its pty runs (the worktree
    /// dir for an isolated session), `repoRoot` the project root the per-project
    /// worktree default is keyed by. With that default on, the new worktree has to be
    /// cut from the main checkout: the core cuts it off git's `--show-toplevel`, which
    /// from inside a worktree would nest a `<repo>-worktrees/<name>-worktrees/…`
    /// sibling. With it off, the new session shares the source session's checkout.
    public static func cloning(provider: ProviderId, sessionCwd: String, repoRoot: String,
                               worktreeDefault: (String) -> Bool) -> NewSessionTarget {
        let worktree = worktreeDefault(repoRoot)
        return NewSessionTarget(provider: provider, cwd: worktree ? repoRoot : sessionCwd,
                                isolateWorktree: worktree)
    }
}

/// Arrow-key movement through the ⌘⇧N chooser's provider list. Wraps at both ends
/// so one key reaches every agent; an unknown current provider starts at the top.
public enum ProviderChoice {
    public static func step(_ current: ProviderId, by delta: Int,
                            in providers: [ProviderId] = ProviderId.allCases) -> ProviderId {
        guard !providers.isEmpty else { return current }
        guard let i = providers.firstIndex(of: current) else { return providers[0] }
        let n = providers.count
        return providers[((i + delta) % n + n) % n]
    }
}
