import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Conversation parsing + comment-task prompt backing the GitHub view. Pure
/// functions only — no `gh` is spawned (same approach as `GhTests.swift`).
final class GhConversationTests: XCTestCase {
    // MARK: - fixtures

    /// A realistic response: one issue comment, one review verdict, and two
    /// threads (one active with two comments, one resolved+outdated and empty).
    private let fullFixture = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN",
      "comments":{"nodes":[
        {"id":"IC_1","databaseId":111,"author":{"login":"alice"},
         "body":"Looks good overall","createdAt":"2026-07-01T12:00:00Z",
         "url":"https://github.com/o/r/pull/5#issuecomment-111"}
      ]},
      "reviews":{"nodes":[
        {"id":"PRR_1","author":{"login":"bob"},"state":"changes_requested",
         "body":"Needs tests","createdAt":"2026-07-01T13:30:00.500Z",
         "url":"https://github.com/o/r/pull/5#pullrequestreview-1"}
      ]},
      "reviewThreads":{"nodes":[
        {"id":"RT_1","isResolved":false,"isOutdated":false,
         "path":"Sources/App/Main.swift","line":42,
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":222,"author":{"login":"bob"},
            "body":"This can crash on nil","createdAt":"2026-07-01T13:31:00Z",
            "url":"https://github.com/o/r/pull/5#discussion_r222"},
           {"id":"RC_2","databaseId":333,"author":{"login":"carol"},
            "body":"Agreed","createdAt":"2026-07-01T13:32:00Z",
            "url":"https://github.com/o/r/pull/5#discussion_r333"}
         ]}},
        {"id":"RT_2","isResolved":true,"isOutdated":true,
         "path":"README.md","line":null,"comments":{"nodes":[]}}
      ]}
    }}}}
    """

    /// Everything optional nulled or garbage: the parse must survive with nils
    /// and fallbacks, not fail.
    private let minimalFixture = """
    {"data":{"repository":{"pullRequest":{
      "state":"MERGED",
      "comments":{"nodes":[
        {"id":"IC_1","databaseId":null,"author":null,"body":null,
         "createdAt":"not a date","url":null}
      ]},
      "reviews":{"nodes":[
        {"id":"PRR_1","author":null,"state":null,"body":null,
         "createdAt":null,"url":null}
      ]},
      "reviewThreads":{"nodes":[
        {"id":"RT_1","isResolved":false,"isOutdated":false,
         "path":"a.txt","line":null,
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":null,"author":null,"body":null,
            "createdAt":null,"url":null}
         ]}}
      ]}
    }}}}
    """

    // MARK: - parsing

    func testParsesFullConversation() throws {
        let conv = try XCTUnwrap(parsePrConversation(fullFixture))
        XCTAssertEqual(conv.state, "OPEN")

        XCTAssertEqual(conv.issueComments.count, 1)
        let ic = conv.issueComments[0]
        XCTAssertEqual(ic.id, "IC_1")
        XCTAssertEqual(ic.databaseId, 111)
        XCTAssertEqual(ic.author, "alice")
        XCTAssertEqual(ic.body, "Looks good overall")
        XCTAssertEqual(ic.url, "https://github.com/o/r/pull/5#issuecomment-111")
        // Plain ISO-8601 date parses.
        XCTAssertEqual(ic.createdAt?.timeIntervalSince1970, 1_782_907_200)

        XCTAssertEqual(conv.reviews.count, 1)
        let review = conv.reviews[0]
        XCTAssertEqual(review.author, "bob")
        // State is normalised upper-case like parsePrActivity's review states.
        XCTAssertEqual(review.state, "CHANGES_REQUESTED")
        XCTAssertEqual(review.body, "Needs tests")
        // Fractional-seconds ISO-8601 date parses too.
        XCTAssertEqual(review.createdAt?.timeIntervalSince1970, 1_782_912_600.5)

        XCTAssertEqual(conv.threads.count, 2)
        let thread = conv.threads[0]
        XCTAssertEqual(thread.path, "Sources/App/Main.swift")
        XCTAssertEqual(thread.line, 42)
        XCTAssertFalse(thread.isResolved)
        XCTAssertFalse(thread.isOutdated)
        XCTAssertEqual(thread.comments.map(\.author), ["bob", "carol"])
    }

    func testParsesMinimalConversationWithNullsAndGarbageDate() throws {
        let conv = try XCTUnwrap(parsePrConversation(minimalFixture))
        XCTAssertEqual(conv.state, "MERGED")

        let ic = conv.issueComments[0]
        XCTAssertNil(ic.databaseId)
        XCTAssertEqual(ic.author, "")
        XCTAssertEqual(ic.body, "")
        XCTAssertEqual(ic.url, "")
        // Garbage createdAt → nil, not a parse failure.
        XCTAssertNil(ic.createdAt)

        XCTAssertNil(conv.reviews[0].createdAt)
        XCTAssertEqual(conv.reviews[0].state, "")

        let thread = conv.threads[0]
        XCTAssertNil(thread.line)
        XCTAssertNil(thread.comments[0].databaseId)
    }

    func testMalformedJsonReturnsNil() {
        XCTAssertNil(parsePrConversation(""))
        XCTAssertNil(parsePrConversation("not json"))
        XCTAssertNil(parsePrConversation("{}"))
        XCTAssertNil(parsePrConversation(#"{"data":{"repository":null}}"#))
        XCTAssertNil(parsePrConversation(#"{"data":{"repository":{"pullRequest":null}}}"#))
    }

    // MARK: - reply target

    func testReplyTargetIdIsFirstCommentsDatabaseId() throws {
        let conv = try XCTUnwrap(parsePrConversation(fullFixture))
        // GitHub's replies API only accepts top-level review comments — the
        // target must be the FIRST comment's REST id, not the last's.
        XCTAssertEqual(conv.threads[0].replyTargetId, 222)
        // Empty thread → nothing to reply to.
        XCTAssertNil(conv.threads[1].replyTargetId)
    }

    func testReplyTargetIdNilWhenFirstCommentHasNoDatabaseId() throws {
        let conv = try XCTUnwrap(parsePrConversation(minimalFixture))
        XCTAssertNil(conv.threads[0].replyTargetId)
    }

    func testResolvedAndOutdatedFlags() throws {
        let conv = try XCTUnwrap(parsePrConversation(fullFixture))
        XCTAssertTrue(conv.threads[1].isResolved)
        XCTAssertTrue(conv.threads[1].isOutdated)
    }

    // MARK: - comment task prompt

    func testCommentTaskPromptCarriesTheComment() {
        let prompt = commentTaskPrompt(
            number: 42, path: "Sources/App/Main.swift", line: 17,
            author: "bob", body: "This can crash on nil",
            url: "https://github.com/o/r/pull/42#discussion_r222")
        XCTAssertTrue(prompt.contains("#42"))
        XCTAssertTrue(prompt.contains("Sources/App/Main.swift:17"))
        XCTAssertTrue(prompt.contains("@bob"))
        XCTAssertTrue(prompt.contains("This can crash on nil"))
        XCTAssertTrue(prompt.contains("https://github.com/o/r/pull/42#discussion_r222"))
        // Must instruct the agent to close the loop on the thread.
        XCTAssertTrue(prompt.lowercased().contains("reply"))
        XCTAssertTrue(prompt.contains("`gh`"))
    }

    func testCommentTaskPromptWithoutPathOmitsLocation() {
        let prompt = commentTaskPrompt(
            number: 7, path: nil, line: nil,
            author: "", body: "Top-level note",
            url: "https://github.com/o/r/pull/7#issuecomment-1")
        XCTAssertFalse(prompt.contains(" on `"))
        // Author fallback matches the tracker's "a reviewer" voice.
        XCTAssertTrue(prompt.contains("a reviewer"))
        XCTAssertTrue(prompt.contains("#7"))
    }

    func testCommentTaskPromptWithPathButNoLine() {
        let prompt = commentTaskPrompt(
            number: 7, path: "README.md", line: nil,
            author: "alice", body: "typo", url: "u")
        XCTAssertTrue(prompt.contains("`README.md`"))
        XCTAssertFalse(prompt.contains("README.md:"))
    }
}
