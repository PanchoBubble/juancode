import Foundation

/// A cheap whole-tree change summary for a session's working directory: the number
/// of changed files, total line additions/deletions vs HEAD, and a `signature` of
/// the name-status list used to debounce the review badge. Distinct from the
/// ChangesPanel's per-file unified diffs — this is the light rollup the sidebar
/// badge and session banner show once an agent settles a turn.
public struct ChangeStat: Sendable, Equatable {
    public let files: Int
    public let additions: Int
    public let deletions: Int
    /// Stable fingerprint of the changed name-status set — the debounce key.
    public let signature: String

    public init(files: Int, additions: Int, deletions: Int, signature: String) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.signature = signature
    }

    public var isEmpty: Bool { files == 0 }

    /// Compact label like `3 files · +120 −44`. Uses the real minus sign (−).
    public var summary: String {
        "\(files) file\(files == 1 ? "" : "s") · +\(additions) −\(deletions)"
    }
}

/// A deterministic fingerprint of a `git status --porcelain` name-status list.
/// Sorted so a mere re-ordering never re-badges — only an added/removed path or a
/// changed status code shifts it, which is exactly "the diff changed since I last
/// looked".
public func changeStatSignature(_ entries: [WorktreeStatusEntry]) -> String {
    entries
        .map { "\($0.index)\($0.workTree) \($0.origPath.map { $0 + " -> " } ?? "")\($0.path)" }
        .sorted()
        .joined(separator: "\n")
}

/// Whether a settle edge should recompute a session's review badge. The review
/// moment is a non-editor agent finishing a turn: a real `busy → idle`/`waiting`
/// boundary (`notify`), not a teardown reset or a mid-turn flicker.
public func shouldComputeChangeBadge(prev: SessionActivity?, next: SessionActivity,
                                     notify: Bool, isEditor: Bool) -> Bool {
    if isEditor { return false }
    guard notify else { return false }
    return prev == .busy && next != .busy
}

/// Whether a computed stat should surface as a badge, given what the session's
/// Changes panel last showed. Hidden when clean or unchanged since last viewed.
public func changeBadgeVisible(latest: ChangeStat?, viewedSignature: String?) -> Bool {
    guard let latest, !latest.isEmpty else { return false }
    return latest.signature != viewedSignature
}
