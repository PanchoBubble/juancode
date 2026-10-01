import Foundation

/// A folder tree over a diff's changed files, for the rail's Diff tab. Folders
/// carry the summed counts of everything under them, and a chain of folders with a
/// single child folder and no files is collapsed into one `a/b/c` node, as VS Code's
/// compact folders do, so a deep `Sources/Foo/Bar` doesn't cost three rows.
public struct DiffTreeNode: Sendable, Equatable, Identifiable {
    /// The full repo-relative path: a folder's path for a folder, the file's for a file.
    public let id: String
    /// What the row shows: the file name, or the (possibly compacted) folder segment.
    public let name: String
    public let file: DiffFile?
    public let children: [DiffTreeNode]
    public let additions: Int
    public let deletions: Int

    public var isFolder: Bool { file == nil }
}

/// Build the tree. Folders sort before files, each alphabetically (case-insensitive).
public func buildDiffTree(_ files: [DiffFile]) -> [DiffTreeNode] {
    final class Dir {
        var dirs: [String: Dir] = [:]
        var files: [DiffFile] = []
    }
    let top = Dir()
    for f in files {
        var parts = f.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { continue }
        parts.removeLast()
        var d = top
        for p in parts {
            if let next = d.dirs[p] { d = next } else { let n = Dir(); d.dirs[p] = n; d = n }
        }
        d.files.append(f)
    }

    func nodes(_ d: Dir, prefix: String) -> [DiffTreeNode] {
        let folders = d.dirs.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key -> DiffTreeNode in
                var name = key
                var dir = d.dirs[key]!
                while dir.files.isEmpty, dir.dirs.count == 1, let (k, only) = dir.dirs.first {
                    name += "/" + k
                    dir = only
                }
                let path = prefix + name
                let kids = nodes(dir, prefix: path + "/")
                return DiffTreeNode(id: path, name: name, file: nil, children: kids,
                                    additions: kids.reduce(0) { $0 + $1.additions },
                                    deletions: kids.reduce(0) { $0 + $1.deletions })
            }
        let leaves = d.files
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { f in
                DiffTreeNode(id: f.path, name: (f.path as NSString).lastPathComponent, file: f,
                             children: [], additions: f.additions, deletions: f.deletions)
            }
        return folders + leaves
    }
    return nodes(top, prefix: "")
}
