import Foundation

/// One changed entry in a worktree's `git status --porcelain` output: a path plus
/// its index (X) and work-tree (Y) status codes. This is the groundwork model a
/// future file-tree sidebar and Quick Open index consume — a light, whole-tree
/// change snapshot, distinct from the ChangesPanel's per-file unified diffs.
public struct WorktreeStatusEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// Repo-relative path (the new path for a rename).
    public let path: String
    /// The path a rename came from, else nil.
    public let origPath: String?
    /// Index (staged) status code, e.g. `M`, `A`, `D`, `R`, or a space.
    public let index: Character
    /// Work-tree (unstaged) status code, or a space.
    public let workTree: Character

    public init(path: String, origPath: String? = nil, index: Character, workTree: Character) {
        self.path = path
        self.origPath = origPath
        self.index = index
        self.workTree = workTree
    }

    /// Untracked (`??`) — not yet known to git.
    public var untracked: Bool { index == "?" && workTree == "?" }
}

/// Parse `git status --porcelain` (v1) output into per-path entries. Each line is
/// `XY <path>`, with renames/copies as `XY <orig> -> <new>`. Lenient: malformed
/// lines are skipped rather than throwing.
public func parseWorktreeStatus(_ raw: String) -> [WorktreeStatusEntry] {
    var entries: [WorktreeStatusEntry] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        // `XY` then a space then the path — need at least "XY ?".
        guard line.count >= 4 else { continue }
        let chars = Array(line)
        let index = chars[0]
        let workTree = chars[1]
        let rest = String(chars[3...])
        if index == "R" || index == "C" || workTree == "R" || workTree == "C",
           let arrow = rest.range(of: " -> ") {
            let orig = String(rest[..<arrow.lowerBound])
            let new = String(rest[arrow.upperBound...])
            entries.append(WorktreeStatusEntry(path: new, origPath: orig, index: index, workTree: workTree))
        } else {
            entries.append(WorktreeStatusEntry(path: rest, index: index, workTree: workTree))
        }
    }
    return entries
}
