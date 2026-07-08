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
