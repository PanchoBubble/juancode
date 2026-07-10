import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the pure flat-list → directory-tree builder backing the native
/// ChangesPanel file tree (juancode-dxg). No SwiftUI / git — only data shaping.
final class FileTreeTests: XCTestCase {

    private func file(_ path: String, add: Int = 0, del: Int = 0,
                      status: FileStatus = .modified) -> DiffFile {
        DiffFile(path: path, oldPath: nil, status: status, additions: add, deletions: del,
                 binary: false, diff: "", truncated: false)
    }

    func testFlatFilesBecomeLeavesAtRoot() {
        let tree = buildFileTree([file("b.swift"), file("a.swift")])
        XCTAssertEqual(tree.count, 2)
        // Sorted case-insensitively: a before b.
        XCTAssertEqual(tree.map(\.name), ["a.swift", "b.swift"])
        XCTAssertTrue(tree.allSatisfy { !$0.isDirectory })
        XCTAssertEqual(tree[0].file?.path, "a.swift")
        XCTAssertEqual(tree[0].id, "a.swift")
    }

    func testGroupsFilesUnderSharedDirectory() {
        let tree = buildFileTree([
            file("src/a.swift"),
            file("src/b.swift"),
            file("README.md"),
        ])
        // Folder ("src") sorts before file ("README.md").
        XCTAssertEqual(tree.map(\.name), ["src", "README.md"])
        let src = tree[0]
        XCTAssertTrue(src.isDirectory)
        XCTAssertEqual(src.id, "src")
        XCTAssertEqual(src.children?.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(src.children?[0].id, "src/a.swift")
        XCTAssertFalse(tree[1].isDirectory)
    }

    func testCollapsesSingleChildFolderChain() {
        // A deep path with no siblings collapses to one folder row "a/b/c".
        let tree = buildFileTree([file("a/b/c/deep.swift")])
        XCTAssertEqual(tree.count, 1)
        let folder = tree[0]
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.name, "a/b/c")
        // The combined node keeps the deepest folder's id.
        XCTAssertEqual(folder.id, "a/b/c")
        XCTAssertEqual(folder.children?.map(\.name), ["deep.swift"])
        XCTAssertEqual(folder.children?[0].id, "a/b/c/deep.swift")
    }

    func testDoesNotCollapseWhenFolderBranches() {
        let tree = buildFileTree([
            file("a/b/one.swift"),
            file("a/c/two.swift"),
        ])
        // "a" branches into b and c, so it must NOT collapse.
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a")
        XCTAssertEqual(tree[0].children?.map(\.name), ["b", "c"])
    }

    func testFoldersSortBeforeFilesThenAlphabetical() {
        let tree = buildFileTree([
            file("zfile.txt"),
            file("afile.txt"),
            file("dir/x.txt"),
            file("adir/y.txt"),
        ])
        XCTAssertEqual(tree.map(\.name), ["adir", "dir", "afile.txt", "zfile.txt"])
    }

    func testAggregatesAddDelAcrossSubtree() {
        let tree = buildFileTree([
            file("src/a.swift", add: 3, del: 1),
            file("src/sub/b.swift", add: 10, del: 2),
        ])
        let src = tree[0]
        XCTAssertEqual(src.name, "src")
        XCTAssertEqual(src.additions, 13)
        XCTAssertEqual(src.deletions, 3)
        // Leaf reports its own counts.
        XCTAssertEqual(src.children?.first(where: { $0.name == "a.swift" })?.additions, 3)
    }

    func testFileLeavesFlattensSubtreeInOrder() {
        let tree = buildFileTree([
            file("src/a.swift"),
            file("src/sub/b.swift"),
            file("top.swift"),
        ])
        let allPaths = tree.flatMap(\.fileLeaves).map(\.path)
        XCTAssertEqual(Set(allPaths), ["src/a.swift", "src/sub/b.swift", "top.swift"])
    }

    func testDirectoryNodeIDsCollectsEveryFolder() {
        let tree = buildFileTree([
            file("a/b/one.swift"),
            file("a/c/two.swift"),
        ])
        let ids = directoryNodeIDs(tree)
        XCTAssertTrue(ids.contains("a"))
        XCTAssertTrue(ids.contains("a/b"))
        XCTAssertTrue(ids.contains("a/c"))
        // File leaves are not directories.
        XCTAssertFalse(ids.contains("a/b/one.swift"))
    }

    func testIgnoresEmptyPaths() {
        XCTAssertTrue(buildFileTree([file("")]).isEmpty)
    }

    // MARK: - buildPathTree (file-tree sidebar: full worktree listing, no DiffFile)

    func testPathTreeLeavesCarryNoFileAndKeepPathIds() {
        let tree = buildPathTree(["src/a.swift", "src/b.swift", "README.md"])
        XCTAssertEqual(tree.map(\.name), ["src", "README.md"])
        let src = tree[0]
        XCTAssertTrue(src.isDirectory)
        XCTAssertEqual(src.children?.map(\.id), ["src/a.swift", "src/b.swift"])
        XCTAssertTrue(src.children?.allSatisfy { !$0.isDirectory && $0.file == nil } ?? false)
        XCTAssertNil(tree[1].file)
        XCTAssertFalse(tree[1].isDirectory)
    }

    func testPathTreeSortsFoldersBeforeFilesCaseInsensitively() {
        let tree = buildPathTree(["zfile.txt", "Afile.txt", "dir/x.txt", "aDir/y.txt"])
        XCTAssertEqual(tree.map(\.name), ["aDir", "dir", "Afile.txt", "zfile.txt"])
    }

    func testPathTreeCollapsesSingleChildFolderChain() {
        let tree = buildPathTree(["a/b/c/deep.swift"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a/b/c")
        XCTAssertEqual(tree[0].id, "a/b/c")
        XCTAssertEqual(tree[0].children?.map(\.id), ["a/b/c/deep.swift"])
    }

    func testPathTreeDoesNotCollapseThroughAFileLeaf() {
        // A folder whose single child is a FILE must stay a folder row — the chain
        // collapse only merges folder-into-folder.
        let tree = buildPathTree(["a/file.txt"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a")
        XCTAssertTrue(tree[0].isDirectory)
        XCTAssertEqual(tree[0].children?.map(\.name), ["file.txt"])
    }

    func testPathTreeFolderWithFileAndSubfolderSortsFolderFirst() {
        let tree = buildPathTree(["a/file.txt", "a/b/nested.txt"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a")
        XCTAssertEqual(tree[0].children?.map(\.name), ["b", "file.txt"])
    }

    func testPathTreeIgnoresEmptyPaths() {
        XCTAssertTrue(buildPathTree([""]).isEmpty)
    }

    // MARK: - changedAncestorDirIDs (changed-descendants rollup)

    func testChangedAncestorDirIDsCollectsEveryPrefix() {
        let dirs = changedAncestorDirIDs(["a/b/c.txt", "a/d.txt", "top.txt"])
        XCTAssertEqual(dirs, ["a", "a/b"])
    }

    func testChangedAncestorDirIDsMatchesCollapsedChainNodeIds() {
        // A collapsed chain node keeps the deepest folder's id ("a/b/c"), which is
        // among the prefixes — so the rollup dot lands on the collapsed row too.
        let tree = buildPathTree(["a/b/c/deep.swift", "other.txt"])
        let dirs = changedAncestorDirIDs(["a/b/c/deep.swift"])
        XCTAssertTrue(dirs.contains(tree[0].id))
    }

    func testChangedAncestorDirIDsEmptyForRootLevelChanges() {
        XCTAssertTrue(changedAncestorDirIDs(["top.txt"]).isEmpty)
        XCTAssertTrue(changedAncestorDirIDs([]).isEmpty)
    }
}
