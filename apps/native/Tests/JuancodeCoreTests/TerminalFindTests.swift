import Testing
@testable import JuancodeCore

/// Unit tests for the pure find-in-scrollback core (juancode-972): ANSI stripping,
/// match indexing, and wrapping navigation.
@Suite struct TerminalFindTests {
    // MARK: - ANSI extraction

    @Test func plainTextPassesThrough() {
        #expect(TerminalTextExtractor.lines(fromANSI: "hello world") == ["hello world"])
    }

    @Test func splitsOnNewlines() {
        #expect(TerminalTextExtractor.lines(fromANSI: "a\nb\nc") == ["a", "b", "c"])
    }

    @Test func stripsSGRColorCodes() {
        // Red "error" then reset.
        let s = "\u{1B}[31merror\u{1B}[0m done"
        #expect(TerminalTextExtractor.lines(fromANSI: s) == ["error done"])
    }

    @Test func stripsCursorMoveSequences() {
        // A CSI cursor-position sequence is removed entirely (the extractor does not
        // reposition text on absolute moves — text after it just continues inline).
        let s = "abc\u{1B}[5Gdef"
        #expect(TerminalTextExtractor.lines(fromANSI: s) == ["abcdef"])
    }

    @Test func stripsOSCTitleSequence() {
        // OSC set-window-title, BEL-terminated, should vanish entirely.
        let s = "\u{1B}]0;my title\u{07}prompt$ "
        #expect(TerminalTextExtractor.lines(fromANSI: s) == ["prompt$"])
    }

    @Test func stripsOSCTerminatedByST() {
        // OSC terminated by ST (ESC \) instead of BEL.
        let s = "\u{1B}]0;title\u{1B}\\text"
        #expect(TerminalTextExtractor.lines(fromANSI: s) == ["text"])
    }

    @Test func carriageReturnOverwrites() {
        #expect(TerminalTextExtractor.lines(fromANSI: "foo\rbar") == ["bar"])
        #expect(TerminalTextExtractor.lines(fromANSI: "hello\rH") == ["Hello"])
    }

    @Test func backspaceMovesLeft() {
        // A progress bar that backs up and rewrites a digit.
        #expect(TerminalTextExtractor.lines(fromANSI: "50%\u{08}\u{08}\u{08}99%") == ["99%"])
    }

    @Test func tabAdvancesToStop() {
        #expect(TerminalTextExtractor.lines(fromANSI: "a\tb") == ["a       b"])
    }

    @Test func dropsTrailingBlankLines() {
        #expect(TerminalTextExtractor.lines(fromANSI: "a\n\n\n") == ["a"])
    }

    @Test func trimsTrailingSpacesPerLine() {
        #expect(TerminalTextExtractor.lines(fromANSI: "hi   \nbye") == ["hi", "bye"])
    }

    @Test func incompleteEscapeAtEndIsDropped() {
        // A trailing partial CSI (chunk boundary) must not crash or leak bytes.
        #expect(TerminalTextExtractor.lines(fromANSI: "text\u{1B}[") == ["text"])
    }

    @Test func extractsFromBytes() {
        let bytes = Array("hi\nthere".utf8)
        #expect(TerminalTextExtractor.lines(fromANSI: bytes) == ["hi", "there"])
        #expect(TerminalTextExtractor.text(fromANSI: bytes) == "hi\nthere")
    }

    // MARK: - matching

    @Test func emptyQueryFindsNothing() {
        #expect(TerminalFind.matches(of: "", in: ["anything"]).isEmpty)
    }

    @Test func caseInsensitiveByDefault() {
        let m = TerminalFind.matches(of: "error", in: ["ERROR: bad", "no problem"])
        #expect(m == [TerminalMatch(line: 0, start: 0, length: 5)])
    }

    @Test func caseSensitiveWhenAsked() {
        let m = TerminalFind.matches(of: "error", in: ["ERROR", "error"], caseSensitive: true)
        #expect(m == [TerminalMatch(line: 1, start: 0, length: 5)])
    }

    @Test func multipleMatchesPerLineInOrder() {
        let m = TerminalFind.matches(of: "ab", in: ["ababc"])
        #expect(m == [
            TerminalMatch(line: 0, start: 0, length: 2),
            TerminalMatch(line: 0, start: 2, length: 2),
        ])
    }

    @Test func matchesSpanLinesInReadingOrder() {
        let m = TerminalFind.matches(of: "x", in: ["--x--", "no", "x x"])
        #expect(m == [
            TerminalMatch(line: 0, start: 2, length: 1),
            TerminalMatch(line: 2, start: 0, length: 1),
            TerminalMatch(line: 2, start: 2, length: 1),
        ])
    }

    @Test func matchOffsetsAreCharacterBased() {
        // A multi-byte emoji before the match: offset counts Characters, not bytes.
        let m = TerminalFind.matches(of: "hit", in: ["🎉 hit"])
        #expect(m == [TerminalMatch(line: 0, start: 2, length: 3)])
    }

    // MARK: - navigation

    @Test func stepWithNoMatchesIsNil() {
        #expect(TerminalFind.step(from: nil, count: 0, forward: true) == nil)
        #expect(TerminalFind.step(from: 2, count: 0, forward: false) == nil)
    }

    @Test func stepFromNilStartsAtEnds() {
        #expect(TerminalFind.step(from: nil, count: 5, forward: true) == 0)
        #expect(TerminalFind.step(from: nil, count: 5, forward: false) == 4)
    }

    @Test func stepForwardWraps() {
        #expect(TerminalFind.step(from: 0, count: 3, forward: true) == 1)
        #expect(TerminalFind.step(from: 2, count: 3, forward: true) == 0)
    }

    @Test func stepBackwardWraps() {
        #expect(TerminalFind.step(from: 1, count: 3, forward: false) == 0)
        #expect(TerminalFind.step(from: 0, count: 3, forward: false) == 2)
    }
}
