import XCTest
@testable import JuancodeCore

/// Unit tests for the pure review-flow helpers behind the ChangesPanel: stable
/// per-file hashing, viewed-state reset-on-change, clamped nav, and collapse-by-default.
final class DiffReviewTests: XCTestCase {

    private func file(_ path: String, diff: String = "", additions: Int = 1, deletions: Int = 0,
                      status: FileStatus = .modified, binary: Bool = false, truncated: Bool = false) -> DiffFile {
        DiffFile(path: path, oldPath: nil, status: status, additions: additions,
                 deletions: deletions, binary: binary, diff: diff, truncated: truncated)
    }

    // MARK: - stable hashing

    func testStableHashIsDeterministic() {
        XCTAssertEqual(stableHash("hello"), stableHash("hello"))
        XCTAssertNotEqual(stableHash("hello"), stableHash("world"))
    }

    func testFileDiffHashChangesWithContent() {
        let a = file("a.txt", diff: "one")
        let b = file("a.txt", diff: "two")
        XCTAssertNotEqual(fileDiffHash(a), fileDiffHash(b))
        XCTAssertEqual(fileDiffHash(a), fileDiffHash(file("a.txt", diff: "one")))
    }

    // MARK: - viewed-state reset-on-change

    func testViewedResetsOnlyForChangedFile() {
        let a = file("a.txt", diff: "aaa")
        let b = file("b.txt", diff: "bbb")
        var viewed: [String: String] = [:]
        viewed = markingViewed(a, in: viewed)
        viewed = markingViewed(b, in: viewed)
        XCTAssertTrue(isFileViewed(a, viewed: viewed))
        XCTAssertTrue(isFileViewed(b, viewed: viewed))

        // a's content changes on the next load — it re-appears as unviewed; b does not.
        let aChanged = file("a.txt", diff: "aaa-edited")
        XCTAssertFalse(isFileViewed(aChanged, viewed: viewed))
        XCTAssertTrue(isFileViewed(b, viewed: viewed))
    }

    func testViewedCount() {
        let a = file("a.txt", diff: "aaa")
        let b = file("b.txt", diff: "bbb")
        var viewed: [String: String] = [:]
        XCTAssertEqual(viewedCount([a, b], viewed: viewed), 0)
        viewed = markingViewed(a, in: viewed)
        XCTAssertEqual(viewedCount([a, b], viewed: viewed), 1)
    }

    func testPrunedViewedDropsMissingPaths() {
        let a = file("a.txt", diff: "aaa")
        let b = file("b.txt", diff: "bbb")
        var viewed: [String: String] = [:]
        viewed = markingViewed(a, in: viewed)
        viewed = markingViewed(b, in: viewed)
        let pruned = prunedViewed(viewed, keeping: [a])
        XCTAssertEqual(Set(pruned.keys), ["a.txt"])
    }

    // MARK: - nav index math

    func testSteppedIndexClampsAtEnds() {
        XCTAssertEqual(steppedIndex(current: 0, count: 3, delta: -1), 0)
        XCTAssertEqual(steppedIndex(current: 2, count: 3, delta: 1), 2)
        XCTAssertEqual(steppedIndex(current: 1, count: 3, delta: 1), 2)
        XCTAssertEqual(steppedIndex(current: 1, count: 3, delta: -1), 0)
    }

    func testSteppedIndexFromNil() {
        XCTAssertEqual(steppedIndex(current: nil, count: 3, delta: 1), 0)
        XCTAssertEqual(steppedIndex(current: nil, count: 3, delta: -1), 2)
        XCTAssertNil(steppedIndex(current: nil, count: 0, delta: 1))
    }

    func testHunkCount() {
        XCTAssertEqual(hunkCount(inDiff: ""), 0)
        let diff = """
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        @@ -10,1 +10,1 @@
        -c
        +C
        """
        XCTAssertEqual(hunkCount(inDiff: diff), 2)
    }

    // MARK: - collapse eligibility

    func testGeneratedPaths() {
        XCTAssertTrue(isGeneratedPath("pnpm-lock.yaml"))
        XCTAssertTrue(isGeneratedPath("apps/web/package-lock.json"))
        XCTAssertTrue(isGeneratedPath("dist/bundle.min.js"))
        XCTAssertTrue(isGeneratedPath("styles.min.css"))
        XCTAssertTrue(isGeneratedPath("out.js.map"))
        XCTAssertFalse(isGeneratedPath("src/app.ts"))
        XCTAssertFalse(isGeneratedPath("README.md"))
    }

    func testCollapsedByDefault() {
        XCTAssertTrue(isCollapsedByDefault(file("yarn.lock", additions: 2)))
        XCTAssertTrue(isCollapsedByDefault(file("big.ts", additions: 300, deletions: 200)))
        XCTAssertTrue(isCollapsedByDefault(file("img.png", binary: true)))
        XCTAssertTrue(isCollapsedByDefault(file("huge.ts", truncated: true)))
        XCTAssertFalse(isCollapsedByDefault(file("small.ts", additions: 10, deletions: 5)))
    }

    func testCollapseSummary() {
        XCTAssertEqual(collapseSummary(for: file("img.png", binary: true)), "Binary file")
        XCTAssertEqual(collapseSummary(for: file("yarn.lock", additions: 40, deletions: 10)),
                       "Generated file · 50 changes")
        XCTAssertEqual(collapseSummary(for: file("big.ts", additions: 300, deletions: 200)),
                       "Large diff · 500 changes")
        XCTAssertNil(collapseSummary(for: file("small.ts", additions: 3, deletions: 1)))
    }
}
