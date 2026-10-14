import Foundation

/// The repo a working directory belongs to, for grouping sessions by project. A
/// juancode worktree lives in a sibling `<repo>-worktrees/<name>` dir (see
/// `createWorktree`); map it back to `<repo>` so its sessions nest under the
/// project instead of floating as their own hash-named folder. Any other path is
/// its own project.
///
/// This is the naming-convention heuristic shared by the sidebar grouping and the
/// store's per-project retention cap. The app refines it at runtime with git's
/// authoritative worktree→repo map where available; the store, which has no git
/// context, uses this directly.
public func projectCwd(for cwd: String) -> String {
    let url = URL(fileURLWithPath: cwd)
    let parent = url.deletingLastPathComponent()
    let parentName = parent.lastPathComponent
    guard parentName.hasSuffix("-worktrees") else { return cwd }
    let repoBase = String(parentName.dropLast("-worktrees".count))
    guard !repoBase.isEmpty else { return cwd }
    return parent.deletingLastPathComponent().appendingPathComponent(repoBase).path
}

/// Which persisted sessions to archive at launch so each project keeps at most
/// `keep` of them. Newest by `updatedAt` stay; archived and `protected` sessions
/// (live, pinned, about to be revived) are neither archived nor counted.
public func launchArchiveOverflow(
    _ metas: [SessionMeta],
    keep: Int,
    projectKey: (String) -> String,
    protected: Set<String>
) -> [String] {
    guard keep > 0 else { return [] }
    var seen: [String: Int] = [:]
    var overflow: [String] = []
    let candidates = metas
        .filter { !$0.archived && !protected.contains($0.id) }
        .sorted { $0.updatedAt > $1.updatedAt }
    for meta in candidates {
        let key = projectKey(meta.cwd)
        let count = (seen[key] ?? 0) + 1
        seen[key] = count
        if count > keep { overflow.append(meta.id) }
    }
    return overflow
}
