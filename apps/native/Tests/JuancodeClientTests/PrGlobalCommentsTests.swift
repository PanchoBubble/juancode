import Testing
@testable import JuancodeClient

@Suite struct PrGlobalCommentsTests {
    @Test func globalConversationKeepsIssueCommentsAndReviewSummariesOnly() {
        let issue = PrConversationComment(id: "IC_1", author: "hubber", body: "Overall question")
        let review = PrReviewItem(id: "PRR_1", author: "reviewer", state: "CHANGES_REQUESTED",
                                  body: "Please add coverage")
        let inline = PrConversationComment(id: "RC_1", author: "reviewer",
                                           body: "File anchored", path: "Sources/App.swift", line: 8)
        let timeline = PrTimeline(items: [
            .commit(PrCommit(oid: "abc1234"), id: "commit:abc1234", createdAt: 1),
            .comment(issue, id: "comment:IC_1", createdAt: 2),
            .review(PrReviewItem(id: "PRR_EMPTY", body: " \n\t"), threadGroups: [],
                    id: "review:PRR_EMPTY", createdAt: 3),
            .review(review,
                    threadGroups: [PrThreadGroup(id: "RT_1", path: inline.path,
                                                 line: inline.line, comments: [inline])],
                    id: "review:PRR_1", createdAt: 4),
        ], threads: [PrReviewThread(id: "RT_1", path: "Sources/App.swift", line: 8,
                                    comments: [inline])])

        let comments = prGlobalComments(timeline)

        #expect(comments.map(\.id) == ["comment:IC_1", "review:PRR_1"])
        #expect(comments.map(\.author) == ["hubber", "reviewer"])
        #expect(comments.map(\.body) == ["Overall question", "Please add coverage"])
        #expect(comments.map(\.createdAt) == [2, 4])
        #expect(comments.first?.kind == .comment)
        #expect(comments.last?.kind == .review(state: "CHANGES_REQUESTED"))
        #expect(!comments.contains { $0.body == inline.body })
    }

    @Test func missingTimelineHasNoGlobalComments() {
        #expect(prGlobalComments(nil).isEmpty)
        #expect(prGlobalComments(PrTimeline()).isEmpty)
    }

    @Test func selectionOrderAddsCommentsOnlyForPrReviews() {
        let files = ["Sources/App.swift", "README.md"]

        #expect(reviewSelectionOrder(files, includePrComments: true) == [prGlobalCommentsPath] + files)
        #expect(reviewSelectionOrder(files, includePrComments: false) == files)
    }

    @Test func initialSelectionStaysFileFirstAndFallsBackToComments() {
        #expect(reviewInitialSelection(["README.md"], includePrComments: true) == "README.md")
        #expect(reviewInitialSelection([], includePrComments: true) == prGlobalCommentsPath)
        #expect(reviewInitialSelection([], includePrComments: false) == nil)
    }
}
