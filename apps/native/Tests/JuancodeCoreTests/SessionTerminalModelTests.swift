import Foundation
import Testing
import SwiftTerm
@testable import JuancodeCore

/// Phase 1 of juancode-a2h: the headless VT model stands up and its read API
/// extracts exactly what a SwiftTerm terminal renders for the same byte stream.
@Suite struct SessionTerminalModelTests {
    private func esc(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func writesPlainTextAndTracksCursor() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("hello"))
        #expect(m.visibleText() == "hello")
        // Cursor sits just past the last written column.
        #expect(m.cursorPosition == (x: 5, y: 0))
        let snap = m.snapshot()
        #expect(snap.cols == 20)
        #expect(snap.rows == 4)
        #expect(snap.lines[0].text == "hello")
        #expect(snap.cursorX == 5 && snap.cursorY == 0)
        #expect(!snap.isAlternateBuffer)
    }

    @Test func carriageReturnAndNewline() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("hello\rH"))
        #expect(m.visibleText() == "Hello")
        m.feed(esc("\r\nworld"))
        #expect(m.visibleText() == "Hello\nworld")
    }

    @Test func absoluteCursorPositioning() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("\u{1B}[2;3HX")) // row 2, col 3 (1-based)
        #expect(m.visibleText() == "\n  X")
        #expect(m.cursorPosition == (x: 3, y: 1))
    }

    @Test func sgrColorsAndStyleLandOnCells() {
        let m = SessionTerminalModel(cols: 20, rows: 2, scrollbackLines: 100)
        // Bold + red foreground on "A", then reset, then plain "B".
        m.feed(esc("\u{1B}[1;31mA\u{1B}[0mB"))
        let snap = m.snapshot()
        let cellA = snap.lines[0].cells[0]
        #expect(cellA.char == "A")
        #expect(cellA.fg == .ansi(1))
        #expect(cellA.style.contains(.bold))
        let cellB = snap.lines[0].cells[1]
        #expect(cellB.char == "B")
        #expect(cellB.fg == .default)
        #expect(!cellB.style.contains(.bold))
    }

    @Test func trueColorFidelity() {
        let m = SessionTerminalModel(cols: 20, rows: 2, scrollbackLines: 100)
        m.feed(esc("\u{1B}[38;2;10;20;30mZ"))
        let cell = m.snapshot().lines[0].cells[0]
        #expect(cell.char == "Z")
        #expect(cell.fg == .trueColor(r: 10, g: 20, b: 30))
    }

    @Test func scrollRegionScrollsContent() {
        let m = SessionTerminalModel(cols: 10, rows: 5, scrollbackLines: 100)
        // Fill 5 lines, then the sixth forces a scroll: the top line drops off.
        m.feed(esc("L1\r\nL2\r\nL3\r\nL4\r\nL5"))
        #expect(m.visibleText() == "L1\nL2\nL3\nL4\nL5")
        m.feed(esc("\r\nL6"))
        #expect(m.visibleText() == "L2\nL3\nL4\nL5\nL6")
    }

    @Test func alternateScreenEnterAndExit() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("normal"))
        #expect(!m.isAlternateBuffer)
        m.feed(esc("\u{1B}[?1049h")) // enter alt screen
        #expect(m.isAlternateBuffer)
        m.feed(esc("\u{1B}[2J\u{1B}[Halt-content"))
        #expect(m.snapshot().isAlternateBuffer)
        #expect(m.visibleText() == "alt-content")
        m.feed(esc("\u{1B}[?1049l")) // exit alt screen — normal buffer restored
        #expect(!m.isAlternateBuffer)
        #expect(m.visibleText() == "normal")
    }

    @Test func cursorVisibilityTracksDecTcem() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        #expect(m.snapshot().cursorVisible)
        m.feed(esc("\u{1B}[?25l")) // hide cursor
        #expect(!m.snapshot().cursorVisible)
        m.feed(esc("\u{1B}[?25h")) // show cursor
        #expect(m.snapshot().cursorVisible)
    }

    @Test func damageStreamEmitsOnChange() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        let box = DamageBox()
        m.onDamage { box.record($0) }
        m.feed(esc("hi"))
        #expect(box.count >= 1)
        #expect(box.last?.startY == 0)
    }

    @Test func resizeReflowsGrid() {
        let m = SessionTerminalModel(cols: 40, rows: 10, scrollbackLines: 100)
        m.feed(esc("hello"))
        m.resize(cols: 20, rows: 4)
        #expect(m.cols == 20)
        #expect(m.rows == 4)
        #expect(m.visibleText() == "hello")
    }

    @Test func oscTitleIsCaptured() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("\u{1B}]0;my-title\u{07}"))
        #expect(m.terminalTitle == "my-title")
    }

    /// Acceptance: the model's snapshot matches, line for line, what an independent
    /// SwiftTerm `Terminal` renders for the same byte stream — a compact golden
    /// exercising cursor moves, colors, a scroll, and alt-screen enter/exit.
    @Test func snapshotMatchesReferenceTerminal() {
        let stream = esc(
            "\u{1B}[2J\u{1B}[H" +                       // clear + home
            "\u{1B}[1;34mheader line\u{1B}[0m\r\n" +    // styled row
            "second row here\r\n" +
            "\u{1B}[3;5Hjumped\r\n" +                   // absolute move then text
            "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng" +         // force scrolling
            "\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt world"   // alt screen
        )

        let m = SessionTerminalModel(cols: 24, rows: 8, scrollbackLines: 200)
        m.feed(stream)

        let ref = ReferenceTerminal(cols: 24, rows: 8)
        ref.terminal.feed(byteArray: stream)

        #expect(m.isAlternateBuffer == ref.terminal.isCurrentBufferAlternate)
        let cursor = m.cursorPosition
        #expect((cursor.x, cursor.y) == ref.terminal.getCursorLocation())
        for r in 0..<8 {
            let modelRow = m.styledVisibleLine(at: r)?.text ?? ""
            // Normalize the reference the same way the model renders a blank cell
            // (never-written cells decode to NUL), then trim trailing blanks.
            let refRaw = ref.terminal.getLine(row: r)?.translateToString(trimRight: false) ?? ""
            var refRow = refRaw.replacingOccurrences(of: "\u{0}", with: " ")
            while refRow.hasSuffix(" ") { refRow.removeLast() }
            #expect(modelRow == refRow, "row \(r) mismatch: model=\(modelRow.debugDescription) ref=\(refRow.debugDescription)")
        }
    }
}

/// An independent reference `Terminal` in tests, driven by a bare delegate, so the
/// model's extracted snapshot can be compared against a stock SwiftTerm render.
private final class ReferenceTerminal {
    let terminal: Terminal
    private let delegate = NoopTerminalDelegate()
    init(cols: Int, rows: Int) {
        var opts = TerminalOptions.default
        opts.cols = cols
        opts.rows = rows
        terminal = Terminal(delegate: delegate, options: opts)
    }
}

private final class NoopTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Collects damage deltas off the model's callback (fired on the feeding thread).
private final class DamageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [TerminalDamage] = []
    func record(_ d: TerminalDamage) { lock.withLock { deltas.append(d) } }
    var count: Int { lock.withLock { deltas.count } }
    var last: TerminalDamage? { lock.withLock { deltas.last } }
}
