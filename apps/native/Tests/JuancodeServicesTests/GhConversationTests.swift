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
      "body":"This PR fixes the thing.",
      "comments":{"nodes":[
        {"id":"IC_1","databaseId":111,
         "author":{"login":"alice","avatarUrl":"https://avatars.example/alice.png"},
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
        XCTAssertEqual(conv.body, "This PR fixes the thing.")

        XCTAssertEqual(conv.issueComments.count, 1)
        let ic = conv.issueComments[0]
        XCTAssertEqual(ic.id, "IC_1")
        XCTAssertEqual(ic.databaseId, 111)
        XCTAssertEqual(ic.author, "alice")
        XCTAssertEqual(ic.authorAvatarUrl, "https://avatars.example/alice.png")
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
        // No `body` key in the fixture → empty description, not a parse failure.
        XCTAssertEqual(conv.body, "")

        let ic = conv.issueComments[0]
        XCTAssertNil(ic.databaseId)
        XCTAssertEqual(ic.author, "")
        XCTAssertNil(ic.authorAvatarUrl)
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

    // MARK: - grouped reviews + commits

    /// A review carrying two inline comments, a bare approval, an empty
    /// COMMENTED review (must be dropped), matching threads (for resolution
    /// lookup), and two commits.
    private let groupedFixture = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN",
      "comments":{"nodes":[]},
      "reviews":{"nodes":[
        {"id":"PRR_1","author":{"login":"bob"},"state":"changes_requested",
         "body":"Two things","createdAt":"2026-07-01T10:00:00Z","url":"u1",
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":222,"author":{"login":"bob"},"body":"nil crash",
            "createdAt":"2026-07-01T10:00:01Z","url":"d222","path":"a.swift","line":42},
           {"id":"RC_2","databaseId":333,"author":{"login":"bob"},"body":"rename",
            "createdAt":"2026-07-01T10:00:02Z","url":"d333","path":"b.swift","line":7}
         ]}},
        {"id":"PRR_2","author":{"login":"carol"},"state":"approved","body":"",
         "createdAt":"2026-07-01T11:00:00Z","url":"u2","comments":{"nodes":[]}},
        {"id":"PRR_3","author":{"login":"dave"},"state":"commented","body":"",
         "createdAt":"2026-07-01T12:00:00Z","url":"u3","comments":{"nodes":[]}}
      ]},
      "reviewThreads":{"nodes":[
        {"id":"RT_1","isResolved":true,"isOutdated":false,"path":"a.swift","line":42,
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":222,"author":{"login":"bob"},"body":"nil crash",
            "createdAt":"2026-07-01T10:00:01Z","url":"d222","path":"a.swift","line":42}
         ]}}
      ]},
      "commits":{"nodes":[
        {"commit":{"oid":"abc1234567","abbreviatedOid":"abc1234",
          "messageHeadline":"fix: guard nil","committedDate":"2026-07-01T10:30:00Z",
          "authors":{"nodes":[{"name":"Bob B","user":{"login":"bob"}}]}}},
        {"commit":{"oid":"def7654321","abbreviatedOid":null,
          "messageHeadline":"chore: rename","committedDate":"2026-07-01T10:40:00Z",
          "authors":{"nodes":[{"name":"Local Only","user":null}]}}}
      ]}
    }}}}
    """

    func testGroupsReviewInlineCommentsAndDropsEmptyReview() throws {
        let conv = try XCTUnwrap(parsePrConversation(groupedFixture))
        // The empty COMMENTED review (no body, no comments) is dropped; the
        // verdict + the approval survive.
        XCTAssertEqual(conv.reviews.map(\.id), ["PRR_1", "PRR_2"])
        let review = conv.reviews[0]
        XCTAssertEqual(review.comments.map(\.id), ["RC_1", "RC_2"])
        XCTAssertEqual(review.comments[0].path, "a.swift")
        XCTAssertEqual(review.comments[0].line, 42)
        XCTAssertEqual(review.comments[1].path, "b.swift")
        // Approval kept even with no body/comments.
        XCTAssertEqual(conv.reviews[1].state, "APPROVED")
        XCTAssertTrue(conv.reviews[1].comments.isEmpty)
    }

    func testThreadInfoLookupCrossReferencesResolution() throws {
        let conv = try XCTUnwrap(parsePrConversation(groupedFixture))
        // RC_1 belongs to a resolved thread; the reply target is its db id.
        let info = try XCTUnwrap(conv.threadInfo(forCommentId: "RC_1"))
        XCTAssertTrue(info.isResolved)
        XCTAssertFalse(info.isOutdated)
        XCTAssertEqual(info.replyTargetId, 222)
        // RC_2 has no matching thread in the fixture → no info.
        XCTAssertNil(conv.threadInfo(forCommentId: "RC_2"))
    }

    func testParsesCommits() throws {
        let conv = try XCTUnwrap(parsePrConversation(groupedFixture))
        XCTAssertEqual(conv.commits.count, 2)
        XCTAssertEqual(conv.commits[0].abbreviatedOid, "abc1234")
        XCTAssertEqual(conv.commits[0].messageHeadline, "fix: guard nil")
        // Prefers the GitHub login when present…
        XCTAssertEqual(conv.commits[0].author, "bob")
        // …falls back to abbreviating oid, and to the raw name for a local author.
        XCTAssertEqual(conv.commits[1].abbreviatedOid, "def7654")
        XCTAssertEqual(conv.commits[1].author, "Local Only")
    }

    func testTimelineInterleavesCommitsChronologically() throws {
        let conv = try XCTUnwrap(parsePrConversation(groupedFixture))
        let ids = prTimeline(conv).map(\.id)
        // 10:00 review, 10:30 commit, 10:40 commit, 11:00 approval.
        XCTAssertEqual(ids, ["review:PRR_1", "commit:abc1234567",
                             "commit:def7654321", "review:PRR_2"])
    }

    // MARK: - comment HTML → markdown

    func testCleanCommentHTMLConvertsInlineEmphasis() {
        let out = cleanCommentHTML("<strong>bold</strong> and <em>em</em> and <code>x()</code>")
        XCTAssertEqual(out, "**bold** and *em* and `x()`")
        // <b>/<i> aliases too.
        XCTAssertEqual(cleanCommentHTML("<b>B</b> <i>I</i>"), "**B** *I*")
    }

    func testCleanCommentHTMLConvertsLinksImagesHeadingsLists() {
        XCTAssertEqual(
            cleanCommentHTML(#"<a href="https://x.dev">docs</a>"#),
            "[docs](https://x.dev)")
        XCTAssertEqual(
            cleanCommentHTML(#"<img src="https://x.dev/a.png" alt="pic">"#),
            "![pic](https://x.dev/a.png)")
        XCTAssertTrue(cleanCommentHTML("<h2>Reason</h2>").contains("## Reason"))
        let list = cleanCommentHTML("<ul><li>one</li><li>two</li></ul>")
        XCTAssertTrue(list.contains("- one"))
        XCTAssertTrue(list.contains("- two"))
        XCTAssertFalse(list.contains("<li>"))
    }

    func testCleanCommentHTMLLeavesDetailsForSplitting() {
        // <details>/<summary> must survive cleaning (splitDetails consumes them),
        // while inline tags inside are already converted.
        let out = cleanCommentHTML("<details><summary><strong>Waiting for</strong></summary>x</details>")
        XCTAssertTrue(out.contains("<details"))
        XCTAssertTrue(out.contains("<summary"))
        XCTAssertTrue(out.contains("**Waiting for**"))
        XCTAssertFalse(out.contains("<strong>"))
    }

    // MARK: - comment segments

    func testParseCommentSegmentsSummaryLabelIsCleanedMarkdown() {
        // The screenshot bug: a bot's <details> summary carried raw <strong>,
        // which was shown literally. The summary label must arrive as markdown.
        let segs = parseCommentSegments(
            "intro\n<details><summary><strong>Waiting for</strong></summary>\ninner body\n</details>")
        XCTAssertEqual(segs.count, 2)
        guard case .markdown(let lead) = segs[0] else {
            return XCTFail("expected leading markdown, got \(segs[0])")
        }
        XCTAssertEqual(lead, "intro")
        guard case .details(let summary, let inner) = segs[1] else {
            return XCTFail("expected details, got \(segs[1])")
        }
        XCTAssertEqual(summary, "**Waiting for**")
        XCTAssertEqual(inner, [.markdown("inner body")])
    }

    func testParseCommentSegmentsNestsDetails() {
        let segs = parseCommentSegments(
            "<details><summary>outer</summary><details><summary>inner</summary>deep</details></details>")
        guard case .details(let outerSummary, let outerInner) = segs.first else {
            return XCTFail("expected outer details, got \(String(describing: segs.first))")
        }
        XCTAssertEqual(outerSummary, "outer")
        XCTAssertEqual(outerInner, [.details(summary: "inner", inner: [.markdown("deep")])])
    }
}
