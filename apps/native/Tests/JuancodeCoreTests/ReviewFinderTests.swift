import XCTest
@testable import JuancodeCore

/// The diff-review finders' pure layer (juancode-qqq): smartcase literal search with
/// vim's wrapping `/` `?` `n` `N`, the fuzzy file picker and live grep across files.
final class ReviewFinderTests: XCTestCase {

    private func file(_ path: String, _ diff: String, adds: Int = 0) -> DiffFile {
        DiffFile(path: path, oldPath: nil, status: .modified, additions: adds, deletions: 0,
                 binary: false, diff: diff, truncated: false)
    }

    private let diffA = """
    @@ -1,3 +1,3 @@
     let Foo = 1
    -let foo = 2
    +let bar = 2
     foo(Foo)
    """

    private let diffB = """
    @@ -5,2 +5,2 @@
     fn main() {}
    +// FOO and foo
    """

    // MARK: - Smartcase

    func testSmartcaseIsInsensitiveUntilAnUppercaseLetter() {
        XCTAssertEqual(reviewSmartcaseRanges("foo", in: "Foo foo FOO"), [0..<3, 4..<7, 8..<11])
        XCTAssertEqual(reviewSmartcaseRanges("Foo", in: "Foo foo FOO"), [0..<3])
        XCTAssertEqual(reviewSmartcaseRanges("", in: "foo"), [])
        XCTAssertEqual(reviewSmartcaseRanges("aa", in: "aaaa"), [0..<2, 2..<4], "non-overlapping")
        XCTAssertEqual(reviewSmartcaseRanges(".*", in: "a.*b"), [1..<3], "literal, not a regex")
    }

    func testOffsetsAreCharactersNotBytes() {
        XCTAssertEqual(reviewSmartcaseRanges("x", in: "é—x"), [2..<3])
    }

    // MARK: - In-file search

    func testSearchWrapsAndSkipsHunkHeaders() {
        let rows = reviewRows(for: file("a", diffA))
        // rows: 0 hunk, 1 " let Foo", 2 "-let foo", 3 "+let bar", 4 " foo(Foo)"
        XCTAssertEqual(reviewSearch(rows, pattern: "foo", from: 1, forward: true),
                       ReviewSearchHit(row: 2, wrapped: false))
        XCTAssertEqual(reviewSearch(rows, pattern: "foo", from: 4, forward: true),
                       ReviewSearchHit(row: 1, wrapped: true))
        XCTAssertEqual(reviewSearch(rows, pattern: "foo", from: 1, forward: false),
                       ReviewSearchHit(row: 4, wrapped: true))
        XCTAssertEqual(reviewSearch(rows, pattern: "Foo", from: 1, forward: true),
                       ReviewSearchHit(row: 4, wrapped: false), "smartcase skips `foo`")
        XCTAssertEqual(reviewSearch(rows, pattern: "@@", from: 1, forward: true), nil,
                       "a hunk header is not a hit")
        XCTAssertNil(reviewSearch(rows, pattern: "nope", from: 0, forward: true))
        XCTAssertNil(reviewSearch(rows, pattern: "", from: 0, forward: true))
    }

    func testTheOnlyMatchIsFoundFromItselfAndFromBeforeTheTop() {
        let rows = reviewRows(for: file("a", diffA))
        XCTAssertEqual(reviewSearch(rows, pattern: "bar", from: 3, forward: true),
                       ReviewSearchHit(row: 3, wrapped: true))
        XCTAssertEqual(reviewSearch(rows, pattern: "bar", from: -1, forward: true),
                       ReviewSearchHit(row: 3, wrapped: false))
    }

    // MARK: - File finder

    func testFileFinderListsTreeOrderWhenEmptyAndRanksWhenTyped() {
        let files = [file("src/zeta.swift", ""), file("README.md", ""), file("src/alpha.swift", "")]
        XCTAssertEqual(reviewFileFinder(files, query: "").map(\.file.path),
                       ["src/alpha.swift", "src/zeta.swift", "README.md"])
        let hits = reviewFileFinder(files, query: "zeta")
        XCTAssertEqual(hits.map(\.file.path), ["src/zeta.swift"])
        XCTAssertEqual(hits[0].ranges, [4..<8])
        XCTAssertEqual(reviewFileFinder(files, query: "sw").first?.file.path, "src/alpha.swift")
    }

    func testFileFinderIsSmartcase() {
        let files = [file("Readme.md", ""), file("docs/readme.txt", "")]
        XCTAssertEqual(Set(reviewFileFinder(files, query: "readme").map(\.file.path)),
                       ["Readme.md", "docs/readme.txt"])
        XCTAssertEqual(reviewFileFinder(files, query: "Readme").map(\.file.path), ["Readme.md"])
    }

    func testFileFinderPrefersTheFilename() {
        let files = [file("map/x.swift", ""), file("lib/map.swift", "")]
        XCTAssertEqual(reviewFileFinder(files, query: "map").first?.file.path, "lib/map.swift")
    }

    // MARK: - Live grep

    func testGrepSearchesEveryFileInTreeOrderWithRowsThePanelRenders() {
        let index = reviewGrepIndex([file("b.rs", diffB), file("a.swift", diffA)])
        XCTAssertEqual(index.map(\.path), ["a.swift", "b.rs"])
        let hits = reviewGrep(index, query: "foo")
        XCTAssertEqual(hits.map(\.location), ["a.swift:1", "a.swift:2 (old)", "a.swift:3", "b.rs:6"])
        XCTAssertEqual(hits.map(\.row), [1, 2, 4, 2])
        XCTAssertEqual(hits[3].ranges, [3..<6, 11..<14])
        XCTAssertEqual(hits[3].line.kind, .insert)
        XCTAssertEqual(index[1].rows[hits[3].row].line?.text, "// FOO and foo")
    }

    func testGrepIsSmartcaseCappedAndEmptyForNoQuery() {
        let index = reviewGrepIndex([file("a.swift", diffA), file("b.rs", diffB)])
        XCTAssertEqual(reviewGrep(index, query: "FOO").map(\.location), ["b.rs:6"])
        XCTAssertEqual(reviewGrep(index, query: "foo", limit: 2).count, 2)
        XCTAssertEqual(reviewGrep(index, query: ""), [])
    }
}
