import XCTest
@testable import JuancodeCore

/// Locks the juancode-qce.3 routing contract: staged review comments compose into a
/// single feedback prompt that is handed to the per-session MESSAGE QUEUE (deliver on
/// idle), NOT pasted as several messages. The queue is the seam that guarantees a
/// review never interrupts the agent mid-turn, so it's what we assert on here.
final class ReviewQueueRoutingTests: XCTestCase {
    private func comment(_ file: String, _ line: Int, _ body: String) -> DiffComment {
        DiffComment(id: UUID().uuidString, sessionId: "s1", file: file, side: .new,
                    line: line, endLine: line, body: body, createdAt: 0)
    }

    func testComposedReviewIsQueuedAsOneDeliverOnIdleMessage() {
        let comments = [comment("a.swift", 3, "rename this"), comment("b.swift", 7, "extract helper")]
        let prompt = composeReviewFeedback(comments)
        XCTAssertFalse(prompt.isEmpty)

        let queue = MessageQueue()
        queue.add("s1", text: prompt)

        // Exactly one queued item — the whole review, not a paste-per-comment.
        XCTAssertEqual(queue.list("s1").count, 1)
        XCTAssertEqual(queue.peek("s1")?.text, prompt)
        // Both annotations are carried in the single queued prompt.
        XCTAssertTrue(prompt.contains("a.swift:3"))
        XCTAssertTrue(prompt.contains("b.swift:7"))
    }

    func testEmptyReviewProducesNothingToQueue() {
        XCTAssertEqual(composeReviewFeedback([]), "")
        XCTAssertEqual(composeReviewFeedback([comment("a", 1, "   ")]), "")
    }
}
