// The pure half of the Worktree viewer: which checkout a session is inspecting,
// the navigation state remembered per checkout, and what a file's "current
// contents" honestly are (text, gone, binary, unreadable).
//
// State is keyed by the canonical worktree path, never by session: two sessions in
// the same checkout look at the same files, so they share where the viewer was. What
// is NOT shared is where review feedback goes — that stays keyed by the session that
// wrote it (`DiffReviewModel`), so a shared checkout can never route one agent's
// notes into another's prompt.

import Foundation

public enum WorktreeSection: String, Codable, Sendable, CaseIterable {
    /// Every file in the checkout, changed or not.
    case files
    /// Only what the chosen comparison says changed.
    case changes
}

public enum WorktreeViewerMode: String, Codable, Sendable, CaseIterable {
    /// The file's current contents on disk.
    case file
    /// The file's change under the chosen comparison.
    case diff
}

/// Where the viewer was in one checkout.
public struct WorktreeViewState: Codable, Equatable, Sendable {
    public var section: WorktreeSection
    public var mode: WorktreeViewerMode
    public var comparison: ReviewBase
    /// Worktree-relative path of the open file.
    public var selectedPath: String?
    /// The first visible line (File mode, 1-based) or row (Diff mode) to scroll back to.
    public var scrollLine: Int?
    /// When it was last changed, for evicting the oldest checkouts.
    public var touchedAt: Double

    public init(section: WorktreeSection = .changes, mode: WorktreeViewerMode = .diff,
                comparison: ReviewBase = .head, selectedPath: String? = nil,
                scrollLine: Int? = nil, touchedAt: Double = 0) {
        self.section = section; self.mode = mode; self.comparison = comparison
        self.selectedPath = selectedPath; self.scrollLine = scrollLine; self.touchedAt = touchedAt
    }

    /// Opening a different file starts at its top; re-selecting the open one keeps
    /// the place. The mode is kept either way: File/Diff is a way of looking, not a
    /// property of one file.
    public mutating func select(_ path: String?) {
        guard path != selectedPath else { return }
        selectedPath = path
        scrollLine = nil
    }
}

public enum WorktreeIdentity {
    /// The key a checkout's state lives under: absolute, symlinks resolved (`/tmp` and
    /// `/private/tmp` are one checkout), `.`/`..` folded, no trailing slash. Nil for an
    /// empty path — there is no checkout to remember anything about.
    public static func canonical(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        while url.path.count > 1, url.path.hasSuffix("/") { url.deleteLastPathComponent() }
        return url.path
    }

    /// The checkout a session is actually working in: a worktree the agent cut for
    /// itself mid-session wins over the folder its pty was started in, which wins over
    /// the session's recorded worktree. Never the repository's main checkout unless
    /// that is genuinely where the session runs.
    public static func checkout(agentWorktree: String?, liveCwd: String?, recorded: String?) -> String? {
        for candidate in [agentWorktree, liveCwd, recorded] {
            if let c = candidate, let path = canonical(c) { return path }
        }
        return nil
    }
}

/// Per-checkout viewer state, persisted as one JSON blob. Bounded: the oldest
/// checkouts are forgotten past `limit`, so swept worktrees do not accumulate forever.
public final class WorktreeViewStore: @unchecked Sendable {
    public static let defaultsKey = "worktree.viewState.v1"
    public static let limit = 200

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Double
    private var states: [String: WorktreeViewState]

    public init(defaults: UserDefaults = .standard, key: String = WorktreeViewStore.defaultsKey,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.defaults = defaults
        self.key = key
        self.now = now
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: WorktreeViewState].self, from: data) {
            states = decoded
        } else {
            states = [:]
        }
    }

    /// The state for `worktree` (any spelling of its path), defaults when unseen.
    public func state(_ worktree: String) -> WorktreeViewState {
        guard let k = WorktreeIdentity.canonical(worktree) else { return WorktreeViewState() }
        return states[k] ?? WorktreeViewState()
    }

    public func update(_ worktree: String, _ change: (inout WorktreeViewState) -> Void) {
        guard let k = WorktreeIdentity.canonical(worktree) else { return }
        var s = states[k] ?? WorktreeViewState()
        let before = s
        change(&s)
        guard s != before else { return }
        s.touchedAt = now()
        states[k] = s
        if states.count > Self.limit {
            let oldest = states.sorted { $0.value.touchedAt < $1.value.touchedAt }
                .prefix(states.count - Self.limit).map(\.key)
            for o in oldest { states.removeValue(forKey: o) }
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: key)
    }
}

/// What File mode shows for one path: the bytes on disk now, or why there are none.
public enum WorktreeFileContent: Equatable, Sendable {
    case text(String)
    /// Not on disk: deleted in the working tree (Diff still shows what was removed).
    case missing
    /// On disk but not UTF-8 text.
    case binary
    /// Larger than the viewer will draw.
    case tooLarge(lines: Int)
    case unavailable(String)

    /// Lines the viewer draws at most; past this File mode says so instead.
    public static let maxLines = 20_000

    /// Classify a successful read.
    public static func read(_ text: String) -> WorktreeFileContent {
        var lines = 1
        for b in text.utf8 where b == 0x0A { lines += 1 }
        if lines > maxLines { return .tooLarge(lines: lines) }
        if text.utf8.contains(0) { return .binary }
        return .text(text)
    }

    /// Classify a failed read. The core reports a missing file and a non-UTF-8 one by
    /// message (`git::read_file`); a deleted status settles "missing" without asking.
    public static func failure(_ message: String, status: FileStatus?) -> WorktreeFileContent {
        if status == .deleted { return .missing }
        let m = message.lowercased()
        if m.contains("not utf-8") || m.contains("not utf8") { return .binary }
        if m.contains("could not read file") || m.contains("no such file") { return .missing }
        return .unavailable(message)
    }
}

/// The file the viewer should show after the list it picks from changed: the
/// remembered one while it is still listed, else the first listed one, else none.
/// In Files mode an unchanged file stays selected even though Changes no longer lists
/// it — `listed` is the section being shown.
public func worktreeSelection(remembered: String?, listed: [String]) -> String? {
    if let remembered, listed.contains(remembered) { return remembered }
    return listed.first
}
