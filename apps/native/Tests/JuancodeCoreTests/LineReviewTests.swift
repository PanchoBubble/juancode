import XCTest
@testable import JuancodeCore

/// The diff-review panel's pure layer (juancode-a5j): rows, comment anchoring, the
/// review message (the `diff-review` plugin's `formatReview`, byte for byte), the
/// file tree and the vim key parser.
final class LineReviewTests: XCTestCase {

    private func file(_ path: String, _ diff: String, status: FileStatus = .modified,
                      oldPath: String? = nil, adds: Int = 0, dels: Int = 0) -> DiffFile {
        DiffFile(path: path, oldPath: oldPath, status: status, additions: adds, deletions: dels,
                 binary: false, diff: diff, truncated: false)
    }

    private let sample = """
    diff --git a/src/a.ts b/src/a.ts
    index 1..2 100644
    --- a/src/a.ts
    +++ b/src/a.ts
    @@ -1,4 +1,4 @@
     one
    -two
    +TWO
     three
     \tfour
    @@ -10,2 +10,3 @@ func x
     ten
    +ten-and-a-half
     eleven
    """

    // MARK: - Rows

    func testRowsCarryHunkHeadersLinesAndExpandedTabs() {
        let rows = reviewRows(for: file("src/a.ts", sample))
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows[0], .hunk("@@ -1,4 +1,4 @@"))
        XCTAssertEqual(rows[2].line?.kind, .delete)
        XCTAssertEqual(rows[2].line?.oldLine, 2)
        XCTAssertEqual(rows[3].line?.newLine, 2)
        XCTAssertEqual(rows[5].line?.text, "    four", "a context line indented by a tab")
        XCTAssertEqual(rows[6], .hunk("@@ -10,2 +10,3 @@ func x"))
        XCTAssertEqual(rows[8].line?.newLine, 11)
    }

    func testTabsInsideALineBecomeFourSpaces() {
        let rows = reviewRows(for: file("a", "@@ -1 +1 @@\n+\tx\ty"))
        XCTAssertEqual(rows[1].line?.text, "    x    y")
    }

    func testBinaryAndTruncatedFilesAreANote() {
        var bin = file("img.png", "")
        bin.binary = true
        XCTAssertEqual(reviewRows(for: bin), [.note("binary file")])
        var big = file("big.txt", "")
        big.truncated = true
        XCTAssertEqual(reviewRows(for: big), [.note("diff too large to display")])
    }

    func testLongDiffsAreCutWithANote() {
        let body = (1...50).map { "+l\($0)" }.joined(separator: "\n")
        let rows = reviewRows(for: file("a", "@@ -0,0 +1,50 @@\n" + body), maxLines: 10)
        XCTAssertEqual(rows.count, 11)
        XCTAssertEqual(rows.last, .note("… diff truncated"))
    }

    // MARK: - Anchoring

    func testLineKeysAndLabelsPreferTheNewSide() {
        let rows = reviewRows(for: file("src/a.ts", sample))
        XCTAssertEqual(reviewLineKey(rows[1].line!), "n1")
        XCTAssertEqual(reviewLineKey(rows[2].line!), "o2")
        XCTAssertEqual(reviewLineLabel(rows[2].line!), "2 (old)")
        XCTAssertEqual(reviewLineLabel(rows[3].line!), "2")
    }

    func testACommentSkipsHunkHeadersAndQuotesItsLines() {
        let rows = reviewRows(for: file("src/a.ts", sample))
        let c = makeReviewComment(path: "src/a.ts", rows: rows, from: 3, to: 0, text: "why", id: "x")
        XCTAssertEqual(c, ReviewComment(id: "x", path: "src/a.ts", startLabel: "1", endLabel: "2",
                                        endKey: "n2", excerpt: [" one", "-two", "+TWO"], text: "why"))
    }

    func testARangeOfOnlyHeadersIsNoComment() {
        let rows = reviewRows(for: file("src/a.ts", sample))
        XCTAssertNil(makeReviewComment(path: "p", rows: rows, from: 0, to: 0, text: "t"))
        XCTAssertNil(makeReviewComment(path: "p", rows: [], from: 0, to: 0, text: "t"))
    }

    func testACommentFindsItsLineAgainAfterTheDiffMoves() {
        let before = reviewRows(for: file("src/a.ts", sample))
        let c = makeReviewComment(path: "src/a.ts", rows: before, from: 8, to: 8, text: "t")!
        XCTAssertEqual(c.endKey, "n11")
        // An edit above shifts every row of the second hunk down, but line 11 is still 11.
        let after = reviewRows(for: file("src/a.ts", sample.replacingOccurrences(
            of: "+TWO\n", with: "+TWO\n+inserted\n")))
        let at = reviewRowIndex(forKey: c.endKey, in: after)
        XCTAssertEqual(at, 9)
        XCTAssertEqual(after[at!].line?.text, "ten-and-a-half")
        // A removed line keeps its old-side key.
        XCTAssertEqual(reviewRowIndex(forKey: "o2", in: after), 2)
        XCTAssertNil(reviewRowIndex(forKey: "n999", in: after))
    }

    // MARK: - Review message

    func testFormatReviewMatchesThePlugin() {
        let comments = [
            ReviewComment(id: "1", path: "src/a.ts", startLabel: "1", endLabel: "2", endKey: "n2",
                          excerpt: [" one", "-two", "+TWO"], text: "why uppercase?"),
            ReviewComment(id: "2", path: "b.md", startLabel: "5 (old)", endLabel: "5 (old)",
                          endKey: "o5", excerpt: ["-gone"], text: "keep this\nplease"),
        ]
        let expected = """
        Review comments on my diff (working tree vs HEAD). Address each one:

        1. `src/a.ts:1-2`
        ```diff
         one
        -two
        +TWO
        ```
        why uppercase?

        2. `b.md:5 (old)`
        ```diff
        -gone
        ```
        keep this
        please
        """
        XCTAssertEqual(formatReview(comments, baseLabel: "working tree vs HEAD"), expected)
    }

    func testBaseLabels() {
        XCTAssertEqual(ReviewBase.head.label(), "working tree vs HEAD")
        XCTAssertEqual(ReviewBase.staged.label(), "staged vs HEAD")
        XCTAssertEqual(ReviewBase.main.label(ref: "origin/main"), "working tree vs merge-base(origin/main)")
        XCTAssertEqual(ReviewBase.main.label(), "working tree vs HEAD (no main branch found)")
        XCTAssertEqual(ReviewBase.staged.next, .head)
    }

    // MARK: - Tree

    func testTreeCompressesSingleChildFoldersAndTotalsThem() {
        let files = [
            file("apps/native/Sources/A.swift", "", adds: 3, dels: 1),
            file("apps/native/Sources/B.swift", "", adds: 2),
            file("README.md", "", adds: 1),
        ]
        let rows = reviewTreeRows(files, collapsed: [])
        XCTAssertEqual(rows.map(\.name), ["apps/native/Sources", "A.swift", "B.swift", "README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(rows[0].additions, 5)
        XCTAssertEqual(rows[0].deletions, 1)
        XCTAssertTrue(rows[0].isDirectory)
        XCTAssertEqual(reviewFileOrder(files),
                       ["apps/native/Sources/A.swift", "apps/native/Sources/B.swift", "README.md"])

        let folded = reviewTreeRows(files, collapsed: [rows[0].id])
        XCTAssertEqual(folded.map(\.name), ["apps/native/Sources", "README.md"])
        XCTAssertTrue(folded[0].isCollapsed)
    }

    // MARK: - Keys

    private func run(_ keys: [ReviewKey], visual: Bool = false) -> [ReviewKeyCommand] {
        var p = ReviewKeyParser()
        return keys.compactMap { p.feed($0, visual: visual) }
    }

    private func chars(_ s: String) -> [ReviewKey] { s.map { .char($0) } }

    func testCountsAndMotions() {
        XCTAssertEqual(run(chars("j")), [.down(1)])
        XCTAssertEqual(run(chars("12k")), [.up(12)])
        XCTAssertEqual(run(chars("gg")), [.top])
        XCTAssertEqual(run(chars("G")), [.bottom])
        XCTAssertEqual(run(chars("40G")), [.goToLine(40)])
        XCTAssertEqual(run(chars("40gg")), [.goToLine(40)])
        XCTAssertEqual(run([.ctrl("d"), .ctrl("u")]), [.halfPageDown, .halfPageUp])
        XCTAssertEqual(run(chars("0")), [], "a lone 0 is not a count")
    }

    func testSequences() {
        XCTAssertEqual(run(chars("]c[c2]c")), [.nextHunk(1), .prevHunk(1), .nextHunk(2)])
        XCTAssertEqual(run(chars("gtgT")), [.nextFile(1), .prevFile(1)])
        XCTAssertEqual(run(chars("]d[d")), [.nextComment, .prevComment])
        XCTAssertEqual(run(chars("ddx")), [.deleteComment, .deleteComment])
        XCTAssertEqual(run(chars(" w n e")), [.send, .toggleTree, .focusTree])
        XCTAssertEqual(run([.ctrl("h"), .ctrl("l")]), [.focusTree, .focusDiff])
    }

    func testCommentIsGccInNormalAndGcInVisual() {
        XCTAssertEqual(run(chars("gc")), [], "normal mode waits for the third key")
        XCTAssertEqual(run(chars("gcc")), [.comment])
        XCTAssertEqual(run(chars("gc"), visual: true), [.comment])
        XCTAssertEqual(run(chars("V")), [.toggleVisual])
    }

    func testABrokenSequenceIsDroppedAndEscapeClearsPending() {
        XCTAssertEqual(run(chars("gz")), [])
        XCTAssertEqual(run(chars("gzj")), [.down(1)])
        var p = ReviewKeyParser()
        _ = p.feed(.char("3"), visual: false)
        _ = p.feed(.char("g"), visual: false)
        XCTAssertEqual(p.pending, "3g")
        XCTAssertEqual(p.feed(.escape, visual: false), .escape)
        XCTAssertEqual(p.pending, "")
        XCTAssertEqual(run([.enter]), [.activate])
    }
}
