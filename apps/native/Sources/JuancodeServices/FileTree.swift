import Foundation
import JuancodeCore

/// Pure flat-file-list → directory-tree construction for the native ChangesPanel's
/// VS Code-style "Source Control" file tree (juancode-dxg). Given the flat
/// `[DiffFile]` that `getDiff` produces, it builds a directory hierarchy of
/// collapsible folder nodes and file leaves. No SwiftUI / git here — pure data so
/// it can be unit-tested, mirroring `DiffParse.swift`.

/// One node in the changed-files tree: either a directory (with children) or a
/// file leaf (carrying its `DiffFile`). `id` is the full slash-joined path so it is
/// stable across rebuilds and usable as a SwiftUI selection / expansion key.
public struct FileTreeNode: Sendable, Equatable, Identifiable {
    public let id: String
    /// The trailing path segment shown in the row (folder or file name).
    public let name: String
    /// Present iff this is a directory.
    public let children: [FileTreeNode]?
    /// Present iff this is a file leaf.
    public let file: DiffFile?

    public var isDirectory: Bool { children != nil }

    public init(id: String, name: String, children: [FileTreeNode]?, file: DiffFile?) {
        self.id = id; self.name = name; self.children = children; self.file = file
    }

    /// Aggregate additions across this subtree (the file's own count for a leaf).
    public var additions: Int {
        if let f = file { return f.additions }
        return (children ?? []).reduce(0) { $0 + $1.additions }
    }

    /// Aggregate deletions across this subtree.
    public var deletions: Int {
        if let f = file { return f.deletions }
        return (children ?? []).reduce(0) { $0 + $1.deletions }
    }

    /// Every file leaf in this subtree, in tree order. Convenience for callers that
    /// want the flat set of paths (e.g. expand/collapse-all over folders).
    public var fileLeaves: [DiffFile] {
        if let f = file { return [f] }
        return (children ?? []).flatMap(\.fileLeaves)
    }
}

/// Build the directory tree for a flat list of changed files. Path components are
/// split on "/"; intermediate components become folder nodes, the final component a
/// file leaf. Single-child folder chains are collapsed into one row ("a/b/c") the
/// way IDE source-control trees do, so deep paths stay compact. Folders sort before
/// files, each group alphabetically (case-insensitive); the input file order is
/// otherwise irrelevant. A renamed file is keyed on its new `path`.
public func buildFileTree(_ files: [DiffFile]) -> [FileTreeNode] {
    buildTree(files.map { ($0.path, $0) })
}

/// Build the directory tree for a flat list of worktree-relative paths (e.g. the
/// gitignore-aware `git ls-files` output backing the file-tree sidebar). Same
/// shaping as `buildFileTree` — chain collapsing, folders-first sort — but the
/// leaves carry no `DiffFile`; change decoration is looked up live by node id.
public func buildPathTree(_ paths: [String]) -> [FileTreeNode] {
    buildTree(paths.map { ($0, nil) })
}

/// Shared folding core: flat `(path, payload)` pairs → nested nodes. A leaf is a
/// path that terminates at its node (payload or not); intermediate segments become
/// folders.
private func buildTree(_ items: [(path: String, file: DiffFile?)]) -> [FileTreeNode] {
    // Mutable builder mirrors the immutable FileTreeNode shape during construction.
    final class Builder {
        let segment: String
        let fullPath: String
        var children: [String: Builder] = [:]
        var childOrder: [String] = []
        var file: DiffFile?
        var isLeaf = false
        init(segment: String, fullPath: String) {
            self.segment = segment; self.fullPath = fullPath
        }
        func child(_ seg: String) -> Builder {
            if let existing = children[seg] { return existing }
            let path = fullPath.isEmpty ? seg : "\(fullPath)/\(seg)"
            let b = Builder(segment: seg, fullPath: path)
            children[seg] = b
            childOrder.append(seg)
            return b
        }
    }

    let root = Builder(segment: "", fullPath: "")
    for item in items {
        let parts = item.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { continue }
        var cursor = root
        for seg in parts.dropLast() { cursor = cursor.child(seg) }
        let leaf = cursor.child(parts[parts.count - 1])
        leaf.file = item.file
        leaf.isLeaf = true
    }

    // Collapse a single-child folder chain into one node ("a/b") and recurse, then
    // sort folders-before-files alphabetically.
    func materialize(_ b: Builder) -> FileTreeNode {
        if b.isLeaf, b.children.isEmpty {
            return FileTreeNode(id: b.fullPath, name: b.segment, children: nil, file: b.file)
        }
        // Folder. Collapse a lone subfolder into a combined name.
        if !b.isLeaf, b.children.count == 1,
           let only = b.children[b.childOrder[0]], !only.isLeaf {
            let merged = materialize(only)
            return FileTreeNode(
                id: merged.id,
                name: "\(b.segment)/\(merged.name)",
                children: merged.children, file: nil)
        }
        let kids = b.childOrder.compactMap { b.children[$0] }.map(materialize)
        let sorted = kids.sorted { a, c in
            if a.isDirectory != c.isDirectory { return a.isDirectory && !c.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(c.name) == .orderedAscending
        }
        return FileTreeNode(id: b.fullPath, name: b.segment, children: sorted, file: nil)
    }

    let top = root.childOrder.compactMap { root.children[$0] }.map(materialize)
    return top.sorted { a, c in
        if a.isDirectory != c.isDirectory { return a.isDirectory && !c.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(c.name) == .orderedAscending
    }
}

/// Every ancestor-directory id of the given (changed) worktree-relative paths —
/// the rollup set behind the file-tree sidebar's "this folder has changed
/// descendants" indicator. Ids are slash-joined path prefixes, so membership works
/// for collapsed chain nodes too (their id is the deepest folder's full path).
public func changedAncestorDirIDs(_ paths: some Sequence<String>) -> Set<String> {
    var out: Set<String> = []
    for p in paths {
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { continue }
        var prefix = ""
        for seg in parts.dropLast() {
            prefix = prefix.isEmpty ? String(seg) : "\(prefix)/\(seg)"
            out.insert(prefix)
        }
    }
    return out
}

/// The set of directory node ids in a tree — handy for an "expand all" default so
/// the tree opens fully expanded (IDE behaviour for a small changed-files set).
public func directoryNodeIDs(_ nodes: [FileTreeNode]) -> Set<String> {
    var out: Set<String> = []
    func walk(_ n: FileTreeNode) {
        guard let kids = n.children else { return }
        out.insert(n.id)
        for k in kids { walk(k) }
    }
    for n in nodes { walk(n) }
    return out
}
