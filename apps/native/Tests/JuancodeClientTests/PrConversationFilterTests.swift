import XCTest
import JuancodeClient

final class PrConversationFilterTests: XCTestCase {
    func testUnresolvedKeepsRepliesAndAnchorsButExcludesResolvedThreads() {
        let comments = [PrConversationComment(id: "root", databaseId: 42, body: "Fix this"),
                        PrConversationComment(id: "reply", body: "Working on it")]
        let open = PrThreadGroup(id: "open", path: "file.swift", line: 12,
                                 isOutdated: true, replyTargetId: 42, comments: comments)
        let resolved = PrThreadGroup(id: "resolved", isResolved: true)
        let review = PrReviewItem(id: "review", state: "CHANGES_REQUESTED")
        let items: [PrTimelineItem] = [
            .review(review, threadGroups: [resolved, open], id: "event", createdAt: 123),
            .review(PrReviewItem(id: "approved"), threadGroups: [resolved], id: "done", createdAt: 124),
            .comment(PrConversationComment(id: "comment"), id: "comment", createdAt: 125)
        ]
        XCTAssertEqual(PrConversationFilter.unresolved.apply(to: items), [
            .review(review, threadGroups: [open], id: "event", createdAt: 123)
        ])
        XCTAssertEqual(PrConversationFilter.unresolved.count(in: items), 1)
        XCTAssertEqual(PrConversationFilter.all.apply(to: items), items)
    }

    func testFiltersRetainChronologyAndCountThreadsRatherThanReviewEvents() {
        let comment = PrTimelineItem.comment(PrConversationComment(id: "c"), id: "c", createdAt: 1)
        let commit = PrTimelineItem.commit(PrCommit(oid: "abc"), id: "commit", createdAt: 2)
        let review = PrTimelineItem.review(PrReviewItem(id: "r"), threadGroups: [
            PrThreadGroup(id: "a"), PrThreadGroup(id: "b")
        ], id: "r", createdAt: 3)
        let items = [comment, commit, review]
        XCTAssertEqual(PrConversationFilter.comments.apply(to: items), [comment])
        XCTAssertEqual(PrConversationFilter.reviews.apply(to: items), [review])
        XCTAssertEqual(PrConversationFilter.unresolved.count(in: items), 2)
        XCTAssertEqual(PrConversationFilter.reviews.count(in: items), 1)
        XCTAssertEqual(PrConversationFilter.all.count(in: items), 3)
        XCTAssertTrue(PrConversationFilter.unresolved.apply(to: [comment, commit]).isEmpty)
    }
}
