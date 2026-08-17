import Foundation

/// Dependency reuse for freshly created worktrees.
///
/// A new linked worktree is a bare source checkout: `node_modules` is gitignored, so
/// every worktree would otherwise need its own install before anything can be run or
/// tested. Instead we point each `node_modules` the source checkout already has at the
/// same directory, which is free and instant.
///
/// Symlinks are safe for the resolvers we care about: Node resolves through them by
/// realpath, and pnpm's `.pnpm` store uses links relative to the directory itself, so
/// they still land inside the real tree. The one sharp edge is that an install run
/// *inside* the worktree writes through to the source checkout's `node_modules` —
/// delete the link first if a worktree genuinely needs different dependencies.

/// The maximum depth below the repo root we look for `node_modules` at. Covers the
/// root plus monorepo package dirs (`apps/*`, `packages/*/*`) without walking a whole
/// source tree.
private let maxScanDepth = 3

/// Link every `node_modules` in `sourceRoot` into the matching path under
/// `worktreePath`. Best-effort by design: it is called on the worktree-creation happy
/// path and must never be the reason a session fails to start. Returns the
/// worktree-relative paths it linked, for logging/tests.
@discardableResult
public func linkNodeModules(from sourceRoot: String, to worktreePath: String) -> [String] {
    var linked: [String] = []
    for rel in nodeModulesPaths(under: sourceRoot) {
        let source = (sourceRoot as NSString).appendingPathComponent(rel)
        let dest = (worktreePath as NSString).appendingPathComponent(rel)
        let parent = (dest as NSString).deletingLastPathComponent
        // The package doesn't exist on this branch — nothing to install into.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue
        else { continue }
        // lstat, not stat: a leftover broken link is still "taken", and we never
        // clobber something the checkout already has.
        guard (try? FileManager.default.attributesOfItem(atPath: dest)) == nil else { continue }
        do {
            try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: source)
            linked.append(rel)
        } catch {
            continue
        }
    }
    return linked
}

/// Repo-relative paths of the `node_modules` directories under `root`, breadth-first
/// to `maxScanDepth`. Skips dot-directories and never descends into a `node_modules`
/// it has already found.
private func nodeModulesPaths(under root: String) -> [String] {
    var found: [String] = []
    var frontier: [(rel: String, depth: Int)] = [("", 0)]
    while let (rel, depth) = frontier.popLast() {
        let abs = rel.isEmpty ? root : (root as NSString).appendingPathComponent(rel)
        let modules = rel.isEmpty ? "node_modules" : (rel as NSString).appendingPathComponent("node_modules")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(modules),
                                          isDirectory: &isDir), isDir.boolValue {
            found.append(modules)
        }
        guard depth < maxScanDepth else { continue }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: abs)) ?? []
        for name in names where !name.hasPrefix(".") && name != "node_modules" {
            let child = rel.isEmpty ? name : (rel as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: (root as NSString).appendingPathComponent(child), isDirectory: &childIsDir),
                childIsDir.boolValue else { continue }
            frontier.append((child, depth + 1))
        }
    }
    return found
}
