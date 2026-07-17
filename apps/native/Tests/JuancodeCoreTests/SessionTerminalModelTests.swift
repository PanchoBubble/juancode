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

    /// `bottomText(n)` is the footer / input / dialog region the activity detector
    /// and the seed-delivery checks read: the last n rows with per-row trailing
    /// blanks trimmed, blank rows kept so the region keeps its geometry.
    @Test func bottomTextReturnsLastRowsKeepingBlanks() {
        let m = SessionTerminalModel(cols: 20, rows: 5, scrollbackLines: 100)
        m.feed(esc("top\r\n\r\n\r\n\r\nfooter"))
        #expect(m.bottomText(2) == "\nfooter")
        #expect(m.bottomText(5) == "top\n\n\n\nfooter")
        // Asking for more rows than the grid has clamps to the grid.
        #expect(m.bottomText(9) == "top\n\n\n\nfooter")
        #expect(m.bottomText(0) == "")
    }

    @Test func oscTitleIsCaptured() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("\u{1B}]0;my-title\u{07}"))
        #expect(m.terminalTitle == "my-title")
    }

    /// juancode-a2h.2: `seedBytes()` — the clean-repaint attach seed — reproduces
    /// the model's visible screen (text, cursor, screen mode) when fed into a fresh
    /// terminal, for both a normal styled screen and an alternate-buffer TUI screen.
    /// This is the property the local pane relies on to switch instantly with no
    /// replay-garble.
    @Test func seedBytesReproduceVisibleScreen() {
        let streams = [
            esc("\u{1B}[2J\u{1B}[H\u{1B}[1;31mred\u{1B}[0m plain\r\nsecond row\r\n\u{1B}[4;3Hdeep"),
            esc("\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt row one\r\nalt row two\u{1B}[38;2;9;8;7mtc"),
        ]
        for stream in streams {
            let m = SessionTerminalModel(cols: 24, rows: 6, scrollbackLines: 200)
            m.feed(stream)

            let seeded = SessionTerminalModel(cols: 24, rows: 6, scrollbackLines: 200)
            seeded.feed(m.seedBytes())

            #expect(seeded.isAlternateBuffer == m.isAlternateBuffer)
            #expect(seeded.cursorPosition == m.cursorPosition)
            for r in 0..<6 {
                #expect(seeded.styledVisibleLine(at: r)?.text == m.styledVisibleLine(at: r)?.text,
                        "row \(r) text mismatch after seed")
            }
        }
    }

    /// The seed preserves per-cell SGR (color + style), not just text.
    @Test func seedBytesPreserveCellStyle() {
        let m = SessionTerminalModel(cols: 24, rows: 3, scrollbackLines: 100)
        m.feed(esc("\u{1B}[1;31mR\u{1B}[0m\u{1B}[38;2;9;8;7mT"))

        let seeded = SessionTerminalModel(cols: 24, rows: 3, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        let cells = seeded.snapshot().lines[0].cells
        #expect(cells[0].char == "R")
        #expect(cells[0].fg == .ansi(1))
        #expect(cells[0].style.contains(.bold))
        #expect(cells[1].char == "T")
        #expect(cells[1].fg == .trueColor(r: 9, g: 8, b: 7))
        #expect(!cells[1].style.contains(.bold))
    }

    /// juancode-gwqg: on the primary buffer the seed flows the scrollback history
    /// in above the repainted screen, so a freshly-seeded terminal scrolls back
    /// through the same history the model retains — re-attaching a pane no longer
    /// loses everything above the visible screen.
    @Test func seedBytesReproducePrimaryScrollback() {
        let m = SessionTerminalModel(cols: 10, rows: 3, scrollbackLines: 100)
        // Six lines into a 3-row grid: L1..L3 scroll into history, L4..L6 visible.
        m.feed(esc("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6"))
        #expect(m.visibleText() == "L4\nL5\nL6")
        #expect(m.scrollbackRows == 3)

        let seeded = SessionTerminalModel(cols: 10, rows: 3, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(seeded.visibleText() == m.visibleText())
        #expect(seeded.cursorPosition == m.cursorPosition)
        #expect(seeded.scrollbackRows == 3)
        #expect(seeded.styledScrollbackTail(3).map(\.text) == ["L1", "L2", "L3"])
    }

    /// The scrollback portion of the seed is capped (the receiving view retains a
    /// bounded history), keeping the NEWEST rows.
    @Test func seedBytesCapScrollbackToNewestRows() {
        let m = SessionTerminalModel(cols: 10, rows: 3, scrollbackLines: 100)
        m.feed(esc("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6"))

        let seeded = SessionTerminalModel(cols: 10, rows: 3, scrollbackLines: 100)
        seeded.feed(m.seedBytes(maxScrollbackRows: 2))

        #expect(seeded.visibleText() == m.visibleText())
        #expect(seeded.scrollbackRows == 2)
        #expect(seeded.styledScrollbackTail(2).map(\.text) == ["L2", "L3"])
    }

    /// Flowed scrollback rows keep their per-cell SGR, and a full-width history row
    /// doesn't gain a spurious blank line (the CR clears the pending wrap).
    @Test func seedBytesScrollbackKeepsStyleAndFullWidthRows() {
        let m = SessionTerminalModel(cols: 5, rows: 2, scrollbackLines: 100)
        // A styled full-width row and a styled short row scroll into history.
        m.feed(esc("\u{1B}[1;31mAAAAA\u{1B}[0m\r\n\u{1B}[34mblue\u{1B}[0m\r\nx\r\ny"))
        #expect(m.scrollbackRows == 2)

        let seeded = SessionTerminalModel(cols: 5, rows: 2, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(seeded.scrollbackRows == 2)
        let tail = seeded.styledScrollbackTail(2)
        #expect(tail.map(\.text) == ["AAAAA", "blue"])
        #expect(tail[0].cells[0].fg == .ansi(1))
        #expect(tail[0].cells[0].style.contains(.bold))
        #expect(tail[1].cells[0].fg == .ansi(4))
        #expect(seeded.visibleText() == "x\ny")
    }

    /// A model with no scrollback seeds exactly as before — no flow, no padding.
    @Test func seedBytesWithoutScrollbackLeaveNoHistory() {
        let m = SessionTerminalModel(cols: 10, rows: 4, scrollbackLines: 100)
        m.feed(esc("hello\r\nworld"))

        let seeded = SessionTerminalModel(cols: 10, rows: 4, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(seeded.scrollbackRows == 0)
        #expect(seeded.visibleText() == "hello\nworld")
        #expect(seeded.cursorPosition == m.cursorPosition)
    }

    /// juancode-gwqg: the seed re-asserts the input-relevant modes the program
    /// enabled — mouse reporting, DECCKM application cursor keys, bracketed paste —
    /// so a freshly-seeded view encodes wheel/arrows/paste exactly like a view that
    /// parsed the whole live stream. Without this a re-attached pane had dead
    /// wheel-scroll and normal-mode arrows inside TUIs.
    @Test func seedBytesReproduceInputModes() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1h\u{1B}[?2004h"))
        #expect(m.mouseReportingOn)
        #expect(m.applicationCursorKeys)
        #expect(m.bracketedPaste)

        let seeded = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(seeded.mouseReportingOn)
        #expect(seeded.applicationCursorKeys)
        #expect(seeded.bracketedPaste)
    }

    /// A program that enabled no modes seeds a view with none enabled (the seed
    /// only ever sets modes; a fresh surface starts with everything off).
    @Test func seedBytesLeaveDefaultModesOff() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("plain output"))

        let seeded = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(!seeded.mouseReportingOn)
        #expect(!seeded.applicationCursorKeys)
        #expect(!seeded.bracketedPaste)
    }

    /// Modes survive alongside an alt-screen repaint too (the TUI case that needs
    /// them most).
    @Test func seedBytesReproduceModesOnAlternateScreen() {
        let m = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        m.feed(esc("\u{1B}[?1049h\u{1B}[2J\u{1B}[Htui\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?2004h"))

        let seeded = SessionTerminalModel(cols: 20, rows: 4, scrollbackLines: 100)
        seeded.feed(m.seedBytes())

        #expect(seeded.isAlternateBuffer)
        #expect(seeded.visibleText() == "tui")
        #expect(seeded.mouseReportingOn)
        #expect(seeded.bracketedPaste)
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

    /// Regression for juancode-9goj. SwiftTerm's OSC 8 hyperlink atom table
    /// (`TinyAtom.map`) is process-global and not thread-safe; every `Terminal` in
    /// the process shares it. juancode parses each pty stream in more than one place
    /// on different threads (the headless model on the session workQueue, the GUI
    /// views on the main actor), so a hyperlink-bearing stream fed concurrently must
    /// not corrupt that table. Without the shared `SwiftTermParse` lock this aborts
    /// the test process inside `TinyAtom.lookup` ("unrecognized selector sent to
    /// <garbage>"); with it, the feeds serialize and it completes.
    @Test func concurrentHyperlinkFeedsDoNotCorruptGlobalAtomTable() {
        // OSC 8 hyperlink: ESC ] 8 ; ; URI BEL  text  ESC ] 8 ; ; BEL. Each opening
        // sequence allocates a fresh atom in the shared global map.
        let link = "\u{1B}]8;;https://example.com/\u{07}click\u{1B}]8;;\u{07}\r\n"
        let payload = esc(String(repeating: link, count: 40))
        let models = (0..<4).map { _ in
            SessionTerminalModel(cols: 80, rows: 24, scrollbackLines: 200)
        }
        // Real parallelism across threads: different models feed at the same time,
        // racing the one global atom table. (Two iterations landing on the same model
        // are serialized by that model's own lock; the cross-model race is the target.)
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            let m = models[i % models.count]
            for _ in 0..<40 { m.feed(payload) }
        }
        // Surviving the concurrent feeds without aborting is the real assertion;
        // confirm the models are still consistent afterward.
        for m in models { #expect(m.cols == 80 && m.rows == 24) }
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
