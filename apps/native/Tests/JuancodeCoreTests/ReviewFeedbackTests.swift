import Testing
@testable import JuancodeCore

/// Covers the pure review-feedback composer (juancode-ck4): the numbered
/// `<file>:<line> — <comment>` entries with the annotated diff line quoted beneath,
/// the location label, and the empty/edge cases.
@Suite struct ReviewFeedbackTests {
    private func comment(_ file: String, side: CommentSide = .new, line: Int, endLine: Int? = nil,
                         body: String, quote: String? = nil) -> DiffComment {
        DiffComment(id: file + "\(line)", sessionId: "s", file: file, side: side,
                    line: line, endLine: endLine ?? line, body: body, createdAt: 0, quote: quote)
    }

    @Test func composesNumberedEntriesWithQuotedLines() {
        let comments = [
            comment("src/foo.ts", line: 42, body: "rename this", quote: "+  const x = 1"),
            comment("src/bar.ts", line: 7, body: "drop the log", quote: "+  console.log(x)"),
        ]
        let out = composeReviewFeedback(comments)
        let expected = """
        Review feedback on your changes:
        1. src/foo.ts:42 — rename this
           > +  const x = 1
        2. src/bar.ts:7 — drop the log
           > +  console.log(x)
        Please address each point.
        """
        #expect(out == expected)
    }

    @Test func rangeAndOldSideLabels() {
        #expect(reviewLocationLabel(comment("a", line: 10, endLine: 14, body: "x")) == "a:10-14")
        #expect(reviewLocationLabel(comment("a", side: .old, line: 3, body: "x")) == "a:3 (old)")
        #expect(reviewLocationLabel(comment("a", line: 5, body: "x")) == "a:5")
    }

    @Test func multiLineQuoteAndBodyIndentUnderEntry() {
        let out = composeReviewFeedback([
            comment("a.swift", line: 10, endLine: 11, body: "first line\nsecond line",
                    quote: "+alpha\n+beta"),
        ])
        let expected = """
        Review feedback on your changes:
        1. a.swift:10-11 — first line
           second line
           > +alpha
           > +beta
        Please address each point.
        """
        #expect(out == expected)
    }

    @Test func skipsBlankBodiesAndRenumbers() {
        let out = composeReviewFeedback([
            comment("a", line: 1, body: "   ", quote: "+x"),   // dropped
            comment("b", line: 2, body: "keep me"),
        ])
        let expected = """
        Review feedback on your changes:
        1. b:2 — keep me
        Please address each point.
        """
        #expect(out == expected)
    }

    @Test func entryWithoutQuoteOmitsQuoteLine() {
        let out = composeReviewFeedback([comment("a", line: 1, body: "note")])
        #expect(out == """
        Review feedback on your changes:
        1. a:1 — note
        Please address each point.
        """)
    }

    @Test func emptyWhenNoUsableComments() {
        #expect(composeReviewFeedback([]) == "")
        #expect(composeReviewFeedback([comment("a", line: 1, body: "  \n ")]) == "")
    }
}
