import Testing
@testable import JuancodeCore

/// Unit tests for the headless screen model that backs activity detection.
/// Mirrors `apps/server/src/terminalScreen.test.ts`.
@Suite struct TerminalScreenTests {
    @Test func writesPlainText() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("hello world")
        #expect(s.visibleText == "hello world")
    }

    @Test func carriageReturnOverwrites() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("hello\rH")
        #expect(s.visibleText == "Hello")
    }

    @Test func newlineMovesDown() {
        let s = TerminalScreen(cols: 20, rows: 4)
        // Bare LF moves down but keeps the column (as in xterm); a pty emits CRLF.
        s.feed("a\r\nb")
        #expect(s.visibleText == "a\nb")
    }

    @Test func absoluteCursorPositioning() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("\u{1B}[2;3HX") // row 2, col 3 (1-based)
        #expect(s.visibleText == "\n  X")
    }

    @Test func eraseLineClearsIt() {
        let s = TerminalScreen(cols: 20, rows: 2)
        s.feed("abcdef\r")    // cursor back to col 0
        s.feed("\u{1B}[K")    // erase cursor→end (whole line here)
        #expect(s.visibleText == "")
    }

    @Test func eraseToEndFromCursor() {
        let s = TerminalScreen(cols: 20, rows: 2)
        s.feed("abcdef")
        s.feed("\u{1B}[3G")  // col 3 (1-based) → index 2
        s.feed("\u{1B}[K")
        #expect(s.visibleText == "ab")
    }

    @Test func clearScreen() {
        let s = TerminalScreen(cols: 10, rows: 3)
        s.feed("line1\nline2")
        s.feed("\u{1B}[2J")
        #expect(s.visibleText == "")
    }

    @Test func scrollsOnOverflow() {
        let s = TerminalScreen(cols: 10, rows: 2)
        s.feed("a\r\nb\r\nc") // 'a' scrolls off the top
        #expect(s.visibleText == "b\nc")
    }

    @Test func bufferesEscapeSplitAcrossFeeds() {
        let s = TerminalScreen(cols: 20, rows: 2)
        s.feed("X\u{1B}[2")  // incomplete CSI — must be held
        s.feed("3GY")        // completes to ESC[23G (col 23 → clamped to 19), then Y
        let line = s.visibleText
        #expect(line.hasPrefix("X"))
        #expect(line.hasSuffix("Y"))
    }

    @Test func alternateScreenIsIsolated() {
        let s = TerminalScreen(cols: 10, rows: 2)
        s.feed("main")
        s.feed("\u{1B}[?1049h") // enter alt screen (cleared)
        #expect(s.visibleText == "")
        s.feed("alt")
        #expect(s.visibleText == "alt")
        s.feed("\u{1B}[?1049l") // back to main, preserved
        #expect(s.visibleText == "main")
    }

    /// The crux for footer detection: cursor moves leave real spatial gaps, so the
    /// words stay separated rather than glued ("esctointerrupt").
    @Test func cursorMovesLeaveSpatialGaps() {
        let s = TerminalScreen(cols: 40, rows: 2)
        s.feed("esc\u{1B}[20Gto\u{1B}[30Ginterrupt")
        let t = s.visibleText
        #expect(t.contains("esc"))
        #expect(t.contains("interrupt"))
        #expect(!t.contains("esctointerrupt"))
    }

    @Test func resizePreservesContent() {
        let s = TerminalScreen(cols: 20, rows: 4)
        s.feed("hello")
        s.resize(cols: 40, rows: 6)
        #expect(s.visibleText == "hello")
    }
}
