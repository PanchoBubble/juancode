import XCTest
@testable import JuancodeCore

/// Unit tests for the two halves of the snippet convention (juancode-wx9,
/// juancode-52e8.14.4): `searchSnippet` cuts the text around a match and brackets it,
/// `parseSearchSnippet` splits those brackets into plain/highlighted runs.
final class SearchSnippetTests: XCTestCase {

    func testPlainTextHasNoHighlights() {
        XCTAssertEqual(
            parseSearchSnippet("nothing to mark here"),
            [SnippetRun(text: "nothing to mark here", highlighted: false)])
    }

    func testEmptyStringYieldsNoRuns() {
        XCTAssertEqual(parseSearchSnippet(""), [])
    }

    func testSingleMarkerInMiddle() {
        XCTAssertEqual(
            parseSearchSnippet("fixed the [bug] today"),
            [
                SnippetRun(text: "fixed the ", highlighted: false),
                SnippetRun(text: "bug", highlighted: true),
                SnippetRun(text: " today", highlighted: false),
            ])
    }

    func testMultipleMarkers() {
        XCTAssertEqual(
            parseSearchSnippet("[parse] the [diff] now"),
            [
                SnippetRun(text: "parse", highlighted: true),
                SnippetRun(text: " the ", highlighted: false),
                SnippetRun(text: "diff", highlighted: true),
                SnippetRun(text: " now", highlighted: false),
            ])
    }

    func testEllipsisAroundMarkersIsPlain() {
        // Mirrors the store's snippet() ellipsis sentinel '…'.
        XCTAssertEqual(
            parseSearchSnippet("…wrote a [test]…"),
            [
                SnippetRun(text: "…wrote a ", highlighted: false),
                SnippetRun(text: "test", highlighted: true),
                SnippetRun(text: "…", highlighted: false),
            ])
    }

    func testEmptyMarkerProducesEmptyHighlight() {
        XCTAssertEqual(
            parseSearchSnippet("a[]b"),
            [
                SnippetRun(text: "a", highlighted: false),
                SnippetRun(text: "", highlighted: true),
                SnippetRun(text: "b", highlighted: false),
            ])
    }

    func testUnmatchedOpenBracketIsLiteral() {
        // A '[' with no closing ']' stays plain text (matches the web regex).
        XCTAssertEqual(
            parseSearchSnippet("array[0] index"),
            [
                SnippetRun(text: "array", highlighted: false),
                SnippetRun(text: "0", highlighted: true),
                SnippetRun(text: " index", highlighted: false),
            ])
    }

    func testTrailingUnclosedBracketIsLiteral() {
        XCTAssertEqual(
            parseSearchSnippet("dangling ["),
            [SnippetRun(text: "dangling [", highlighted: false)])
    }

    // MARK: - producing one

    func testBracketsTheMatchAndLeavesTheRestAlone() {
        XCTAssertEqual(
            searchSnippet(in: "the daemon keeps the bytes", matching: "daemon"),
            "the [daemon] keeps the bytes")
        XCTAssertNil(searchSnippet(in: "the daemon keeps the bytes", matching: "nothing here"))
        XCTAssertNil(searchSnippet(in: "anything", matching: ""))
    }

    /// ASCII folding, the same as SQLite's `LIKE` — and the bracketed text is what the
    /// haystack actually says, not the folded form.
    func testMatchesCaseInsensitivelyTheWayLikeDoes() {
        XCTAssertEqual(searchSnippet(in: "Scrollback", matching: "scrollback"), "[Scrollback]")
        XCTAssertEqual(searchSnippet(in: "scrollback", matching: "SCROLLBACK"), "[scrollback]")
    }

    /// Cut on both sides, with the marks that say so — the shape the daemon's
    /// `search.rs` produces, since the panel cannot tell which end wrote a snippet.
    func testCutsALongHaystackOnBothSidesAndSaysSo() throws {
        let text = String(repeating: "a", count: 400) + "needle" + String(repeating: "b", count: 400)
        let out = try XCTUnwrap(searchSnippet(in: text, matching: "needle"))
        XCTAssertTrue(out.hasPrefix("…"), out)
        XCTAssertTrue(out.hasSuffix("…"), out)
        XCTAssertTrue(out.contains("[needle]"), out)
        XCTAssertLessThan(out.count, 200, out)
    }

    func testDoesNotSplitAMultibyteCharacterAtTheWindowEdge() throws {
        let text = String(repeating: "é", count: 100) + "needle" + String(repeating: "→", count: 100)
        let out = try XCTUnwrap(searchSnippet(in: text, matching: "needle"))
        XCTAssertTrue(out.contains("[needle]"), out)
        XCTAssertFalse(out.contains("\u{FFFD}"), "a cut mid-character would decode as U+FFFD: \(out)")
    }

    func testCollapsesAMultiLinePromptToOneRow() throws {
        let out = try XCTUnwrap(
            searchSnippet(in: "first line\nwith a needle\nthen more", matching: "needle"))
        XCTAssertFalse(out.contains("\n"), out)
        XCTAssertEqual(out, "first line with a [needle] then more")
    }

    /// The two halves are each other's inverse: what `searchSnippet` brackets is what
    /// `parseSearchSnippet` highlights.
    func testWhatItBracketsIsWhatTheParserHighlights() throws {
        let out = try XCTUnwrap(searchSnippet(in: "fixed the parser today", matching: "parser"))
        XCTAssertEqual(
            parseSearchSnippet(out).filter(\.highlighted).map(\.text), ["parser"])
    }
}
