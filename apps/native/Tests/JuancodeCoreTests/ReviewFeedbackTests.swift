import Testing
@testable import JuancodeCore

/// Covers the pure review-feedback composer (juancode-ck4): the numbered
/// `<file>:<line> — <comment>` entries with the annotated diff line quoted beneath,
/// the location label, and the empty/edge cases.
@Suite struct ReviewFeedbackTests {
    private func comment(_ file: String, side: CommentSide = .new, line: Int, endLine: Int? = nil,
                         body: String, quote: String? = nil,
                         commitSha: String? = nil, commitSubject: String? = nil) -> DiffComment {
        DiffComment(id: file + "\(line)", sessionId: "s", file: file, side: side,
                    line: line, endLine: endLine ?? line, body: body, createdAt: 0, quote: quote,
                    commitSha: commitSha, commitSubject: commitSubject)
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

    // ── Commit-pointed comments (juancode-5u2) ──────────────────────────────

    @Test func commitCommentsGroupUnderLabeledHeader() {
        let sha = "abc1234def5678900000000000000000000000000"
        let out = composeReviewFeedback([
            comment("a", line: 1, body: "fix this", quote: "+x",
                    commitSha: sha, commitSubject: "add widget"),
            comment("b", line: 2, body: "and this", commitSha: sha, commitSubject: "add widget"),
        ])
        #expect(out == """
        Review feedback on your changes:
        On commit abc1234 – add widget:
        1. a:1 — fix this
           > +x
        2. b:2 — and this
        Please address each point.
        """)
    }

    @Test func mixedBasketKeepsWorkingTreeUnlabeledAndNumberingContinuous() {
        let out = composeReviewFeedback([
            comment("a", line: 1, body: "tree note"),
            comment("b", line: 2, body: "commit note",
                    commitSha: "1111111aaaa", commitSubject: "first"),
            comment("c", line: 3, body: "another tree note"),
        ])
        // Grouping pulls the two tree notes together; numbering follows the
        // emitted order and stays continuous across the commit header.
        #expect(out == """
        Review feedback on your changes:
        1. a:1 — tree note
        2. c:3 — another tree note
        On commit 1111111 – first:
        3. b:2 — commit note
        Please address each point.
        """)
    }

    @Test func distinctCommitsGetSeparateHeadersInFirstAppearanceOrder() {
        let out = composeReviewFeedback([
            comment("a", line: 1, body: "on second", commitSha: "2222222bbbb", commitSubject: "second"),
            comment("b", line: 2, body: "on first", commitSha: "1111111aaaa", commitSubject: "first"),
        ])
        #expect(out == """
        Review feedback on your changes:
        On commit 2222222 – second:
        1. a:1 — on second
        On commit 1111111 – first:
        2. b:2 — on first
        Please address each point.
        """)
    }

    @Test func commitHeaderFallsBackToShaWhenSubjectMissing() {
        let out = composeReviewFeedback([
            comment("a", line: 1, body: "note", commitSha: "3333333cccc"),
        ])
        #expect(out == """
        Review feedback on your changes:
        On commit 3333333:
        1. a:1 — note
        Please address each point.
        """)
    }
}
