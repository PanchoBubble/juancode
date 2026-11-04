import Testing
import JuancodeCore
@testable import JuancodeApp

@Suite struct ReviewMarkdownTests {
    private func line(_ text: String, _ kind: DiffLine.Kind = .insert, number: Int = 1) -> ReviewRow {
        .line(DiffLine(kind: kind, oldLine: kind == .insert ? nil : number,
                       newLine: kind == .delete ? nil : number, text: text))
    }

    @Test func everySourceLineHasAnIndependentCommentTarget() {
        let rows: [ReviewRow] = [
            .hunk("@@ -0,0 +1,10 @@"), line("# Heading"), line(""),
            line("A **bold paragraph", number: 3), line("continued** here.", number: 4), line(""),
            line("```swift"), line("let x = 1"), line("```"), line(""),
            line("- One"), line("- Two")
        ]
        let previews = ReviewMarkdownLine.lines(in: rows, deleted: false)
        #expect(Set(previews.keys) == Set(1..<rows.count))
        #expect(previews[2]?.content == .blank)
        #expect(previews[3]?.content == .markdown("A **bold paragraph**"))
        #expect(previews[4]?.content == .markdown("**continued** here\\."))
        #expect(previews[6]?.content == .blank)
        #expect(previews[7]?.content == .code("let x = 1"))
        #expect(previews[8]?.content == .blank)
        let comment = makeReviewComment(path: "plan.md", rows: rows, from: 3, to: 4, text: "Clarify")
        #expect(comment?.startKey == "n3")
        #expect(comment?.endKey == "n4")
        #expect(comment?.excerpt == ["+A **bold paragraph", "+continued** here."])
    }

    @Test func keepsSidesAndHunksSeparate() {
        let rows: [ReviewRow] = [
            .hunk("first"), line("before", .context), line("removed", .delete),
            line("after"), .hunk("second"), line("later")
        ]
        let added = ReviewMarkdownLine.lines(in: rows, deleted: false)
        #expect(Set(added.keys) == [1, 3, 5])
        #expect(added[3]?.content == .markdown("after"))
        let deleted = ReviewMarkdownLine.lines(in: rows, deleted: true)
        #expect(Set(deleted.keys) == [1, 2])
        let fence = [line("```"), line("old", .delete), line("new"), line("```")]
        let code = ReviewMarkdownLine.lines(in: fence, deleted: false)
        #expect(code[2]?.content == .code("new"))
        #expect(code[1] == nil)
    }

    @Test func resolvesReferencesAndProjectsEachTableRow() {
        let rows = ["[Link][doc]", "", "[doc]: https://example.com", "", "| A | B |",
                    "| --- | --- |", "| 1 | 2 |"].map { line($0) }
        let previews = ReviewMarkdownLine.lines(in: rows, deleted: false)
        #expect(previews[0]?.content == .markdown("[Link](<https://example.com>)"))
        #expect(previews[4]?.content == .table(["A", "B"]))
        #expect(previews[5]?.content == .blank)
        #expect(previews[6]?.content == .table(["1", "2"]))
        // Unrendered metadata remains visible and addressable, never silently lost.
        #expect(previews[2]?.content == .source("[doc]: https://example.com"))
    }

    @Test func preservesEmptyCodeLinesAndUnclosedFenceContent() {
        let rows = ["```", "first", "", "last"].map { line($0) }
        let previews = ReviewMarkdownLine.lines(in: rows, deleted: false)
        #expect(previews[1]?.content == .code("first"))
        #expect(previews[2]?.content == .code(""))
        #expect(previews[3]?.content == .code("last"))
    }
    @Test func keepsListAndInlineContextOnTheOriginalRows() {
        let rows = ["- [x] Done", "  - Nested **item**", "", "[a link", "continued][ref]", "",
                    "[ref]: https://example.com", "", "Use `a*b` here."].map { line($0) }
        let previews = ReviewMarkdownLine.lines(in: rows, deleted: false)
        #expect(previews[0]?.content == .markdown("- [x] Done"))
        #expect(previews[1]?.content == .markdown("- Nested **item**"))
        #expect(previews[1]?.indent == 1)
        #expect(previews[3]?.content == .markdown("[a link](<https://example.com>)"))
        #expect(previews[4]?.content == .markdown("[continued](<https://example.com>)"))
        #expect(previews[8]?.content == .markdown("Use ` a*b ` here\\."))
    }

}
