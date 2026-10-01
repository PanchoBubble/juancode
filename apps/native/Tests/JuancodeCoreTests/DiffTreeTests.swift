import XCTest
@testable import JuancodeCore

final class DiffTreeTests: XCTestCase {
    private func file(_ path: String, _ a: Int, _ d: Int) -> DiffFile {
        DiffFile(path: path, oldPath: nil, status: .modified, additions: a, deletions: d,
                 binary: false, diff: "", truncated: false)
    }

    func testCompactsSingleChildFolderChains() {
        let tree = buildDiffTree([file("apps/native/Sources/A.swift", 3, 1),
                                  file("apps/native/Sources/B.swift", 2, 0)])
        XCTAssertEqual(tree.map(\.name), ["apps/native/Sources"])
        XCTAssertEqual(tree[0].id, "apps/native/Sources")
        XCTAssertEqual(tree[0].children.map(\.name), ["A.swift", "B.swift"])
        XCTAssertEqual(tree[0].additions, 5)
        XCTAssertEqual(tree[0].deletions, 1)
    }

    func testStopsCompactingWhereAFolderBranchesOrHoldsFiles() {
        let tree = buildDiffTree([file("a/x.txt", 1, 0), file("a/b/y.txt", 1, 0),
                                  file("a/b/c/z.txt", 1, 0), file("README.md", 0, 4)])
        XCTAssertEqual(tree.map(\.name), ["a", "README.md"])
        let a = tree[0]
        XCTAssertEqual(a.children.map(\.name), ["b", "x.txt"])
        XCTAssertEqual(a.children[0].children.map(\.id), ["a/b/c", "a/b/y.txt"])
        XCTAssertEqual(a.additions, 3)
    }

    func testEmpty() {
        XCTAssertEqual(buildDiffTree([]), [])
    }
}
