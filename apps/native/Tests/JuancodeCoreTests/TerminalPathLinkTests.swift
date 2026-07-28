import XCTest
@testable import JuancodeCore

final class TerminalPathLinkTests: XCTestCase {
    func testRelativePathWithLine() {
        let r = TerminalPathLink.parse(
            in: "projenrc/workspaces/service-app-integration-workspace.ts:256 — infraMoon",
            preferColumn: 0)
        XCTAssertEqual(r?.path, "projenrc/workspaces/service-app-integration-workspace.ts")
        XCTAssertEqual(r?.line, 256)
    }

    func testPathWithLineAndColumnKeepsLine() {
        let r = TerminalPathLink.parse(in: "apps/native/App.swift:830:12", preferColumn: 0)
        XCTAssertEqual(r?.path, "apps/native/App.swift")
        XCTAssertEqual(r?.line, 830)
    }

    func testBareFilenameWithLineQualifies() {
        // No directory separator, but an explicit :line makes it a path.
        let r = TerminalPathLink.parse(in: "see Session.swift:42 for detail", preferColumn: 0)
        XCTAssertEqual(r?.path, "Session.swift")
        XCTAssertEqual(r?.line, 42)
    }

    func testBareFilenameNoLineNoSlashIsIgnored() {
        // Prose mention of a file with no slash and no line shouldn't resolve.
        XCTAssertNil(TerminalPathLink.parse(in: "it lives in moon.yml somewhere", preferColumn: 0))
    }

    func testProseIsNotAPath() {
        XCTAssertNil(TerminalPathLink.parse(in: "e.g. this is fine vs. that", preferColumn: 0))
    }

    func testUrlIsSkipped() {
        XCTAssertNil(TerminalPathLink.parse(in: "docs at https://ghostty.org/docs here", preferColumn: 0))
    }

    func testTrailingSentencePunctuationTrimmed() {
        let r = TerminalPathLink.parse(in: "edit src/main.rs.", preferColumn: 0)
        XCTAssertEqual(r?.path, "src/main.rs")
        XCTAssertNil(r?.line)
    }

    func testPrefersTokenUnderClickedColumn() {
        let line = "a/first.ts:1 then b/second.ts:2"
        let secondCol = line.distance(from: line.startIndex,
                                      to: line.range(of: "b/second.ts")!.lowerBound)
        let r = TerminalPathLink.parse(in: line, preferColumn: secondCol)
        XCTAssertEqual(r?.path, "b/second.ts")
        XCTAssertEqual(r?.line, 2)
    }

    func testAbsolutePath() {
        let r = TerminalPathLink.parse(in: "/Users/x/proj/file.swift:9", preferColumn: 0)
        XCTAssertEqual(r?.path, "/Users/x/proj/file.swift")
        XCTAssertEqual(r?.line, 9)
    }

    // MARK: URL detection (⌘-click opens the browser, not the editor)

    func testWebUrlDetected() {
        XCTAssertEqual(
            TerminalPathLink.url(in: "https://github.com/PanchoBubble/juancode/pull/42", preferColumn: 5),
            "https://github.com/PanchoBubble/juancode/pull/42")
    }

    func testLocalhostUrlDetected() {
        // The bug this fixes: `localhost` has no dot, so the path parser mis-read the
        // `/foo` tail as a file and opened it in the editor.
        XCTAssertEqual(
            TerminalPathLink.url(in: "open http://localhost:4280/foo now", preferColumn: 15),
            "http://localhost:4280/foo")
    }

    func testUrlTrailingPunctuationTrimmed() {
        XCTAssertEqual(
            TerminalPathLink.url(in: "PR ready: https://example.com/x/y.", preferColumn: 20),
            "https://example.com/x/y")
    }

    func testUrlQueryAndFragmentKept() {
        XCTAssertEqual(
            TerminalPathLink.url(in: "https://example.com/a/b?tab=files#L20", preferColumn: 5),
            "https://example.com/a/b?tab=files#L20")
    }

    func testMailtoDetected() {
        XCTAssertEqual(
            TerminalPathLink.url(in: "reach mailto:dev@example.com today", preferColumn: 12),
            "mailto:dev@example.com")
    }

    func testNoUrlReturnsNil() {
        XCTAssertNil(TerminalPathLink.url(in: "just src/main.rs:9 here", preferColumn: 0))
    }
}
