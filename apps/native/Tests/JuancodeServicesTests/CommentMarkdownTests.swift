import XCTest
@testable import JuancodeServices

/// The comment-body pipeline behind every card the GitHub view draws: the reviewer
/// priority badge lifted out of a bot's markdown, the inline HTML GitHub emits turned
/// back into markdown, and the `<details>`/`<summary>` split that makes a bot's fold a
/// native disclosure rather than four literal tags.
final class CommentMarkdownTests: XCTestCase {
    // MARK: - priority badge

    func testExtractsCodexPriorityBadgeAndLeavesTheTitleFlush() {
        let body = """
        **<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  \
        Reject text alongside GIF-only messages**

        When a caller supplies both.
        """
        let (priority, stripped) = extractCommentPriority(body)
        XCTAssertEqual(priority?.label, "P2")
        XCTAssertEqual(priority?.colorName, "yellow")
        XCTAssertTrue(stripped.hasPrefix("**Reject text alongside GIF-only messages**"),
                      "badge, <sub> wrappers and padding spaces all removed: \(stripped)")
        XCTAssertFalse(stripped.contains("shields.io"))
    }

    func testPriorityBadgeWithoutWrappersOrColourWord() {
        let (p1, _) = extractCommentPriority("![P1 Badge](https://img.shields.io/badge/P1-red)x")
        XCTAssertEqual(p1?.label, "P1")
        XCTAssertEqual(p1?.colorName, "red")
        // A url with no colour word at all → label only, view picks the fallback.
        let (p3, body) = extractCommentPriority("![P3](https://example.com/p3.png) title")
        XCTAssertEqual(p3?.label, "P3")
        XCTAssertNil(p3?.colorName)
        XCTAssertEqual(body, "title")
    }

    func testBodyWithNoBadgeIsReturnedUnchanged() {
        let body = "Just a comment with an ![image](https://x.dev/a.png) in it."
        let (priority, out) = extractCommentPriority(body)
        XCTAssertNil(priority)
        XCTAssertEqual(out, body)
    }

    // MARK: - comment HTML → markdown (continued)

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
