import XCTest
@testable import JuancodeServices

/// Pure timeline-merge + check-outcome helpers backing the GitHub view's PR
/// detail pane. No `gh` is spawned.
final class PrTimelineTests: XCTestCase {
    private func comment(_ id: String, at iso: String?) -> PrConversationComment {
        PrConversationComment(id: id, databaseId: nil, author: "alice", body: "b",
                              createdAt: iso.flatMap(parse), url: "")
    }

    private func review(_ id: String, at iso: String?) -> PrReviewItem {
        PrReviewItem(id: id, author: "bob", state: "COMMENTED", body: "r",
                     createdAt: iso.flatMap(parse), url: "")
    }

    private func parse(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    // MARK: - timeline merge

    func testMergesCommentsAndReviewsChronologically() {
        let items = prTimeline(
            comments: [comment("c1", at: "2026-07-01T10:00:00Z"),
                       comment("c2", at: "2026-07-01T14:00:00Z")],
            reviews: [review("r1", at: "2026-07-01T12:00:00Z")])
        XCTAssertEqual(items.map(\.id), ["comment:c1", "review:r1", "comment:c2"])
    }

    func testUndatedItemsSortLastKeepingInputOrder() {
        let items = prTimeline(
            comments: [comment("c1", at: nil), comment("c2", at: "2026-07-01T10:00:00Z")],
            reviews: [review("r1", at: nil)])
        XCTAssertEqual(items.map(\.id), ["comment:c2", "comment:c1", "review:r1"])
    }

    func testEqualDatesKeepInputOrder() {
        let t = "2026-07-01T10:00:00Z"
        let items = prTimeline(comments: [comment("c1", at: t)], reviews: [review("r1", at: t)])
        XCTAssertEqual(items.map(\.id), ["comment:c1", "review:r1"])
    }

    func testIdsAreNamespacedAcrossKinds() {
        // The same underlying node id must not collide between a comment and a review.
        let items = prTimeline(comments: [comment("X", at: nil)], reviews: [review("X", at: nil)])
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testConversationOverloadUsesIssueCommentsAndReviews() {
        let convo = PrConversation(
            state: "OPEN",
            issueComments: [comment("c1", at: "2026-07-01T10:00:00Z")],
            reviews: [review("r1", at: "2026-07-01T09:00:00Z")],
            threads: [PrReviewThread(id: "t1", isResolved: false, isOutdated: false,
                                     path: "a.txt", line: 1, comments: [])])
        // Threads stay out of the merged timeline.
        XCTAssertEqual(prTimeline(convo).map(\.id), ["review:r1", "comment:c1"])
    }

    // MARK: - check outcome

    private func run(bucket: String, state: String = "") -> PrCheckRun {
        PrCheckRun(name: "ci", state: state, bucket: bucket, link: "")
    }

    func testBucketMapping() {
        XCTAssertEqual(checkOutcome(run(bucket: "pass")), .pass)
        XCTAssertEqual(checkOutcome(run(bucket: "fail")), .fail)
        XCTAssertEqual(checkOutcome(run(bucket: "pending")), .pending)
        XCTAssertEqual(checkOutcome(run(bucket: "skipping")), .skipped)
        XCTAssertEqual(checkOutcome(run(bucket: "cancel")), .skipped)
    }

    func testLegacyStateFallbackWhenBucketMissing() {
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "SUCCESS")), .pass)
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "FAILURE")), .fail)
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "ERROR")), .fail)
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "SKIPPED")), .skipped)
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "NEUTRAL")), .skipped)
        XCTAssertEqual(checkOutcome(run(bucket: "", state: "IN_PROGRESS")), .pending)
    }

    func testFailedPropertyAndOutcomeAgree() {
        for r in [run(bucket: "fail"), run(bucket: "", state: "FAILURE"), run(bucket: "", state: "ERROR")] {
            XCTAssertTrue(r.failed)
            XCTAssertEqual(checkOutcome(r), .fail)
        }
    }
}
