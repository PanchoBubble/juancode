import Testing
import JuancodeCore
@testable import JuancodeApp

@Suite struct ReviewMarkdownTests {
    private func line(_ text: String, _ kind: DiffLine.Kind = .insert, number: Int = 1) -> ReviewRow {
        .line(DiffLine(kind: kind, oldLine: kind == .insert ? nil : number,
                       newLine: kind == .delete ? nil : number, text: text))
    }

    @Test func preservesSourceRowsAcrossMultilineBlocks() {
        let rows: [ReviewRow] = [
            .hunk("@@ -0,0 +1,10 @@"), line("# Heading"), line(""),
            line("A **bold** paragraph", number: 3), line("continued here.", number: 4), line(""),
            line("```swift"), line("let x = 1"), line("```"), line(""),
            line("- One"), line("- Two")
        ]
        let blocks = ReviewMarkdownBlock.blocks(in: rows, deleted: false)
        #expect(blocks.map(\.rows) == [1...1, 3...4, 6...8, 10...11])
        #expect(blocks[2].markdown.contains("let x = 1"))
        // Comments still quote the original source, including Markdown delimiters.
        let comment = makeReviewComment(path: "plan.md", rows: rows, from: 3, to: 4, text: "Clarify")
        #expect(comment?.startKey == "n3")
        #expect(comment?.endKey == "n4")
        #expect(comment?.excerpt == ["+A **bold** paragraph", "+continued here."])
    }

    @Test func omitsRemovedTextWithoutBreakingMarkdownAndKeepsHunksSeparate() {
        let rows: [ReviewRow] = [
            .hunk("first"), line("before", .context), line("removed", .delete),
            line("after"), .hunk("second"), line("later")
        ]
        let blocks = ReviewMarkdownBlock.blocks(in: rows, deleted: false)
        #expect(blocks.map(\.rows) == [1...3, 5...5])
        #expect(!blocks.contains { $0.markdown.contains("removed") })
        let deleted = ReviewMarkdownBlock.blocks(in: rows, deleted: true)
        #expect(deleted.map(\.rows) == [1...2])
        let fence = [line("```"), line("old", .delete), line("new"), line("```")]
        let code = ReviewMarkdownBlock.blocks(in: fence, deleted: false)
        #expect(code.map(\.rows) == [0...3])
        #expect(code.first?.markdown.contains("new") == true)
        #expect(code.first?.markdown.contains("old") == false)
    }

    @Test func resolvesReferenceLinksAndKeepsTableTogether() {
        let rows = ["[Link][doc]", "", "[doc]: https://example.com", "", "| A | B |",
                    "| --- | --- |", "| 1 | 2 |"].map { line($0) }
        let blocks = ReviewMarkdownBlock.blocks(in: rows, deleted: false)
        #expect(blocks.first?.markdown.contains("https://example.com") == true)
        #expect(blocks.last?.rows == 4...6)
    }
}
