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

    /// Nothing changed — and also what a caller shows when the core could not answer,
    /// because an unanswered rollup and a clean tree are the same badge: none.
    public static var empty: ChangeStat {
        ChangeStat(files: 0, additions: 0, deletions: 0, signature: "")
    }

    /// Compact label like `3 files · +120 −44`. Uses the real minus sign (−).
    public var summary: String {
        "\(files) file\(files == 1 ? "" : "s") · +\(additions) −\(deletions)"
    }
}

extension ChangeStat {
    /// The three numbers alone, for the shared files/+/− badge.
    public var counts: DiffCounts {
        DiffCounts(files: files, additions: additions, deletions: deletions)
    }
}

/// A files/additions/deletions triple with no provenance attached — what both the
/// working tree (`ChangeStat`) and a pull request report, so one badge can render
/// either.
public struct DiffCounts: Sendable, Equatable {
    public let files: Int
    public let additions: Int
    public let deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files; self.additions = additions; self.deletions = deletions
    }

    public var isEmpty: Bool { files == 0 && additions == 0 && deletions == 0 }
}
