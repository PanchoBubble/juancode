import Foundation
import SwiftTerm

/// A cell's color, mirrored out of SwiftTerm's `Attribute.Color` into a plain
/// `Sendable` value so a snapshot can cross threads (a view projection, a remote
/// client) without holding a reference into the live emulator.
public enum TerminalColor: Sendable, Equatable {
    case `default`
    case defaultInverted
    case ansi(UInt8)
    case trueColor(r: UInt8, g: UInt8, b: UInt8)
}

/// A cell's text attributes, mirrored out of SwiftTerm's `CharacterStyle`.
public struct TerminalCellStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = TerminalCellStyle(rawValue: 1 << 0)
    public static let underline = TerminalCellStyle(rawValue: 1 << 1)
    public static let blink = TerminalCellStyle(rawValue: 1 << 2)
    public static let inverse = TerminalCellStyle(rawValue: 1 << 3)
    public static let invisible = TerminalCellStyle(rawValue: 1 << 4)
    public static let dim = TerminalCellStyle(rawValue: 1 << 5)
    public static let italic = TerminalCellStyle(rawValue: 1 << 6)
    public static let crossedOut = TerminalCellStyle(rawValue: 1 << 7)
}

/// One rendered grid cell: the grapheme plus its style, extracted from the live
/// emulator. `width` is 1 for normal cells, 2 for the lead cell of a wide glyph
/// (the trailing spacer cell is dropped from `TerminalRow.cells`).
public struct TerminalCell: Sendable, Equatable {
    public var char: Character
    public var width: Int
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var style: TerminalCellStyle

    public init(char: Character, width: Int, fg: TerminalColor, bg: TerminalColor, style: TerminalCellStyle) {
        self.char = char
        self.width = width
        self.fg = fg
        self.bg = bg
        self.style = style
    }
}

/// One rendered line: its styled cells plus the plain text (trailing blanks
/// trimmed), so text-only consumers (search, activity) don't rebuild the string.
public struct TerminalRow: Sendable, Equatable {
    public var cells: [TerminalCell]
    public var text: String

    public init(cells: [TerminalCell], text: String) {
        self.cells = cells
        self.text = text
    }
}

/// A point-in-time projection of the whole visible screen: styled rows, cursor,
/// and screen mode. Everything is a value type, so a view / remote client can hold
/// it without touching the live emulator (the whole point of the epic — views are
/// cheap projections of the model, no re-parse).
public struct TerminalSnapshot: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var lines: [TerminalRow]
    public var cursorX: Int
    public var cursorY: Int
    public var cursorVisible: Bool
    public var isAlternateBuffer: Bool

    public init(
        cols: Int, rows: Int, lines: [TerminalRow],
        cursorX: Int, cursorY: Int, cursorVisible: Bool, isAlternateBuffer: Bool
    ) {
        self.cols = cols
        self.rows = rows
        self.lines = lines
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.cursorVisible = cursorVisible
        self.isAlternateBuffer = isAlternateBuffer
    }

    /// The visible screen as text: rows joined by "\n", trailing blank rows dropped.
    public var text: String {
        var end = lines.count
        while end > 0, lines[end - 1].text.isEmpty { end -= 1 }
        return lines[0..<end].map(\.text).joined(separator: "\n")
    }
}

/// The scroll-invariant row range the emulator marked dirty since the last feed —
/// the damage delta a view projection redraws instead of repainting everything.
/// Indices count from the start of scrollback (survive scrolling), matching
/// `SessionTerminalModel.styledScrollbackLine(at:)`.
public struct TerminalDamage: Sendable, Equatable {
    public var startY: Int
    public var endY: Int
    public init(startY: Int, endY: Int) {
        self.startY = startY
        self.endY = endY
    }
}

/// A headless VT engine for one session: a real SwiftTerm `Terminal` running with
/// no view, fed the pty byte stream ONCE (from `Session.handleData`, on the
/// session workQueue) so the parse happens a single time in the core rather than
/// N times across every attached view. Views (local panes, remote clients, search)
/// become cheap projections of this model — see `snapshot()` and the damage stream.
///
/// Phase 1 of juancode-a2h: this stands up ALONGSIDE the existing byte ring and the
/// byte-fed `ActivityDetector`; it does not yet replace either. It is read-only with
/// respect to the pty — `send` (host device-query responses) is intentionally a
/// no-op so the model never double-answers a query the live view already handled.
///
/// Thread-safety: SwiftTerm's `Terminal` is not thread-safe, so every access (feed,
/// resize, and all reads) goes through `lock`. Feed happens on the session workQueue;
/// reads can come from any thread. `@unchecked Sendable` because the lock is the
/// synchronization invariant and no mutable state escapes unguarded.
public final class SessionTerminalModel: NSObject, TerminalDelegate, @unchecked Sendable {
    public typealias Cancel = @Sendable () -> Void
    /// Fired after each feed that changed the grid, with the coalesced dirty range.
    /// Invoked on the feeding thread (the session workQueue) — hop to your own
    /// executor before touching UI.
    public typealias DamageListener = @Sendable (_ damage: TerminalDamage) -> Void
    public typealias TitleListener = @Sendable (_ title: String) -> Void

    private let lock = NSRecursiveLock()
    private var terminal: Terminal!
    private var cursorVisible = true
    private var lastTitle: String?
    private var damageListeners: [Int: DamageListener] = [:]
    private var titleListeners: [Int: TitleListener] = [:]
    private var nextToken = 0

    /// - Parameters:
    ///   - cols/rows: initial grid, seeded with the pty's spawn size.
    ///   - scrollbackLines: cap on retained scrollback lines (bounds per-session
    ///     memory). The alternate screen (where the agent TUIs live) keeps no
    ///     scrollback regardless — this only bounds the normal buffer.
    public init(cols: Int, rows: Int, scrollbackLines: Int) {
        super.init()
        var opts = TerminalOptions.default
        opts.cols = max(1, cols)
        opts.rows = max(1, rows)
        opts.scrollback = max(0, scrollbackLines)
        self.terminal = Terminal(delegate: self, options: opts)
    }

    // MARK: - feed / resize (write side, on the session workQueue)

    /// Feed a chunk of raw pty bytes into the emulator. Coalesces the resulting
    /// dirty range and emits one damage delta per changed feed.
    public func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let damage: TerminalDamage? = lock.withLock {
            terminal.feed(byteArray: bytes)
            guard let range = terminal.getScrollInvariantUpdateRange() else { return nil }
            terminal.clearUpdateRange()
            return TerminalDamage(startY: range.startY, endY: range.endY)
        }
        guard let damage else { return }
        for l in lock.withLock({ Array(damageListeners.values) }) { l(damage) }
    }

    /// Reflow the model to a new grid — ONE reflow in the core instead of the
    /// per-view SIGWINCH choreography (see the epic). Called from `Session.resize`.
    public func resize(cols: Int, rows: Int) {
        lock.withLock {
            guard cols > 0, rows > 0 else { return }
            terminal.resize(cols: cols, rows: rows)
        }
    }

    // MARK: - read API (thread-safe projections)

    public var cols: Int { lock.withLock { terminal.cols } }
    public var rows: Int { lock.withLock { terminal.rows } }
    public var isAlternateBuffer: Bool { lock.withLock { terminal.isCurrentBufferAlternate } }
    public var cursorPosition: (x: Int, y: Int) { lock.withLock { terminal.getCursorLocation() } }
    /// The last OSC 0/2 window title the program set, if any (OSC handling is free
    /// with the real emulator). `Session` adopts it via `onTitleChange`.
    public var terminalTitle: String? { lock.withLock { lastTitle } }

    /// A full projection of the visible screen. This is what a view renders FROM —
    /// no replay, no re-parse. Matches, cell for cell, what a SwiftTerm view fed the
    /// same byte stream displays.
    public func snapshot() -> TerminalSnapshot {
        lock.withLock {
            let cols = terminal.cols
            let rows = terminal.rows
            var lines: [TerminalRow] = []
            lines.reserveCapacity(rows)
            for r in 0..<rows {
                lines.append(row(terminal.getLine(row: r), cols: cols))
            }
            let cursor = terminal.getCursorLocation()
            return TerminalSnapshot(
                cols: cols, rows: rows, lines: lines,
                cursorX: cursor.x, cursorY: cursor.y,
                cursorVisible: cursorVisible,
                isAlternateBuffer: terminal.isCurrentBufferAlternate)
        }
    }

    /// A single visible row (0-based from the top of the visible screen), or nil if
    /// out of range.
    public func styledVisibleLine(at row: Int) -> TerminalRow? {
        lock.withLock {
            let cols = terminal.cols
            guard row >= 0, row < terminal.rows, let line = terminal.getLine(row: row) else { return nil }
            return self.row(line, cols: cols)
        }
    }

    /// A scrollback line by its scroll-invariant index (counts from the start of
    /// scrollback, so the index is stable as new output scrolls old lines up), or
    /// nil if out of range. `TerminalDamage` ranges use the same coordinate space.
    public func styledScrollbackLine(at scrollInvariantRow: Int) -> TerminalRow? {
        lock.withLock {
            let cols = terminal.cols
            guard let line = terminal.getScrollInvariantLine(row: scrollInvariantRow) else { return nil }
            return self.row(line, cols: cols)
        }
    }

    /// Walk up to `count` scroll-invariant lines starting at `startScrollInvariantRow`,
    /// stopping at the first index that is out of range. A bounded scrollback read for
    /// callers that don't track the exact populated extent.
    public func styledScrollback(fromScrollInvariant startScrollInvariantRow: Int, count: Int) -> [TerminalRow] {
        guard count > 0 else { return [] }
        return lock.withLock {
            let cols = terminal.cols
            var out: [TerminalRow] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let line = terminal.getScrollInvariantLine(row: startScrollInvariantRow + i) else { break }
                out.append(self.row(line, cols: cols))
            }
            return out
        }
    }

    /// How many scrollback history rows to reproduce in `seedBytes()` by default.
    /// Matches SwiftTerm's stock view scrollback (500 lines) — seeding more than
    /// the receiving view retains is pure parse waste.
    public static let defaultSeedScrollbackRows = 500

    /// A clean, well-formed VT byte stream that repaints the model's CURRENT state
    /// (juancode-a2h.2 / juancode-gwqg). Fed to a freshly-attached local view in
    /// place of raw byte replay: because it is synthesized from PARSED state it
    /// carries no partial escape sequences and no stale alt-screen frames, so a
    /// view seeded with it lands the correct screen with no replay-garble and no
    /// synthetic alt-screen resync prefix.
    ///
    /// Exactness (juancode-gwqg — "make attach seeding exact"):
    /// - On the primary buffer, the last `maxScrollbackRows` of scrollback history
    ///   are flowed in above the repainted screen, so the seeded view scrolls back
    ///   through the same history the model retains. Wrapped logical lines arrive
    ///   as hard grid rows (same fidelity the visible-screen repaint already had).
    /// - While the ALTERNATE buffer is active only the alt screen is reproduced:
    ///   SwiftTerm keeps `normalBuffer` private, so the primary screen underneath
    ///   is unreachable through public API (follow-up ticket covers capturing it
    ///   at the buffer flip). Alt-screen TUIs keep no scrollback regardless.
    /// - Input-relevant modes the program enabled are re-asserted — mouse
    ///   reporting (plus SGR encoding, the protocol every TUI we host requests;
    ///   SwiftTerm keeps the exact protocol private), DECCKM application cursor
    ///   keys, and bracketed paste — so a seeded view encodes wheel/arrows/paste
    ///   exactly like a view that parsed the whole live stream. Without this a
    ///   re-attached pane had dead wheel-scroll and normal-mode arrows inside TUIs.
    ///   Modes are only *set* (never reset): the contract is a freshly-created,
    ///   default-state surface.
    public func seedBytes(maxScrollbackRows: Int = SessionTerminalModel.defaultSeedScrollbackRows) -> [UInt8] {
        lock.withLock {
            let cols = terminal.cols
            let rows = terminal.rows
            let alt = terminal.isCurrentBufferAlternate
            let cursor = terminal.getCursorLocation()
            var enc = TerminalSeedEncoder()
            enc.reset()
            enc.setAlternateBuffer(alt)
            enc.clearScreen()
            if !alt {
                // Flow the scrollback tail, then push it fully above the viewport
                // so the absolute-positioned screen repaint below never overlaps it.
                let available = terminal.getTopVisibleRow()
                let count = min(available, max(0, maxScrollbackRows))
                if count > 0 {
                    for r in (available - count)..<available {
                        enc.flowRow(retainedRow(r, cols: cols))
                    }
                    enc.padViewportBelowFlowedRows(rows: rows)
                }
            }
            for r in 0..<rows {
                enc.paintRow(r, row(terminal.getLine(row: r), cols: cols))
            }
            enc.moveCursor(x: cursor.x, y: cursor.y)
            if let code = Self.mouseModeCode(terminal.mouseMode) {
                enc.setPrivateMode(code, true)
                enc.setPrivateMode(1006, true) // SGR extended coordinates
            }
            if terminal.applicationCursor { enc.setPrivateMode(1, true) }
            if terminal.bracketedPasteMode { enc.setPrivateMode(2004, true) }
            enc.setCursorVisible(cursorVisible)
            return enc.bytes
        }
    }

    /// The number of scrollback history rows the model currently retains above the
    /// visible screen (0 while the alternate buffer is active — it keeps none).
    public var scrollbackRows: Int {
        lock.withLock { terminal.getTopVisibleRow() }
    }

    /// The last `count` scrollback history rows (oldest first), styled — exactly
    /// what `seedBytes()` flows in above the repainted screen.
    public func styledScrollbackTail(_ count: Int) -> [TerminalRow] {
        guard count > 0 else { return [] }
        return lock.withLock {
            let cols = terminal.cols
            let available = terminal.getTopVisibleRow()
            let n = min(available, count)
            return (0..<n).map { retainedRow(available - n + $0, cols: cols) }
        }
    }

    // MARK: - input-mode projections (what the seed reproduces)

    public var mouseReportingOn: Bool { lock.withLock { terminal.mouseMode != .off } }
    public var applicationCursorKeys: Bool { lock.withLock { terminal.applicationCursor } }
    public var bracketedPaste: Bool { lock.withLock { terminal.bracketedPasteMode } }

    /// DEC private-mode number for a SwiftTerm mouse mode, nil when reporting is off.
    private static func mouseModeCode(_ mode: Terminal.MouseMode) -> Int? {
        switch mode {
        case .off: return nil
        case .x10: return 9
        case .vt200: return 1000
        case .buttonEventTracking: return 1002
        case .anyEvent: return 1003
        }
    }

    /// The visible screen as text, trailing blank rows dropped. Equivalent to
    /// `snapshot().text` (same cell extraction, so a never-written cell reads as a
    /// blank), without allocating the full styled snapshot.
    public func visibleText() -> String {
        lock.withLock {
            let cols = terminal.cols
            var rowsText: [String] = []
            for r in 0..<terminal.rows {
                rowsText.append(row(terminal.getLine(row: r), cols: cols).text)
            }
            var end = rowsText.count
            while end > 0, rowsText[end - 1].isEmpty { end -= 1 }
            return rowsText[0..<end].joined(separator: "\n")
        }
    }

    /// The last `n` visible rows as text (the footer / input / dialog region):
    /// rows joined by "\n" with per-row trailing blanks trimmed, blank rows kept
    /// so the region's geometry is preserved. What `ActivityDetector` matches its
    /// bottom-region prompt patterns against.
    public func bottomText(_ n: Int) -> String {
        guard n > 0 else { return "" }
        return lock.withLock {
            let cols = terminal.cols
            let rows = terminal.rows
            let start = max(0, rows - n)
            var out: [String] = []
            out.reserveCapacity(rows - start)
            for r in start..<rows {
                out.append(row(terminal.getLine(row: r), cols: cols).text)
            }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - subscriptions

    @discardableResult
    public func onDamage(_ listener: @escaping DamageListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            damageListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.damageListeners.removeValue(forKey: token) } }
    }

    @discardableResult
    public func onTitleChange(_ listener: @escaping TitleListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            titleListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.titleListeners.removeValue(forKey: token) } }
    }

    // MARK: - cell extraction (always under `lock`)

    /// Build a `TerminalRow` from a SwiftTerm `BufferLine`, dropping the trailing
    /// spacer cell of a wide (2-column) glyph so the row's characters read naturally.
    private func row(_ line: BufferLine?, cols: Int) -> TerminalRow {
        guard let line else { return TerminalRow(cells: [], text: "") }
        var cells: [TerminalCell] = []
        cells.reserveCapacity(cols)
        var text = ""
        let limit = min(cols, line.count)
        var i = 0
        while i < limit {
            let width = line.getWidth(index: i)
            // The trailing cell of a wide glyph is a zero-width spacer — drop it so
            // the row's characters line up with the glyphs the view draws.
            if width == 0 {
                i += 1
                continue
            }
            let cd = line[i]
            // An unwritten cell decodes to NUL; render it as a blank.
            let raw = terminal.getCharacter(for: cd)
            let ch: Character = raw == "\u{0}" ? " " : raw
            cells.append(TerminalCell(
                char: ch,
                width: width,
                fg: Self.color(cd.attribute.fg),
                bg: Self.color(cd.attribute.bg),
                style: Self.style(cd.attribute.style)))
            text.append(ch)
            i += 1
        }
        // Trim trailing blanks from the text form (cells keep full width for layout).
        while let last = text.last, last == " " { text.removeLast() }
        return TerminalRow(cells: cells, text: text)
    }

    /// Build a `TerminalRow` from a retained-buffer row (0-based from the start of
    /// retained scrollback; rows `0..<getTopVisibleRow()` are history). Reads cell
    /// by cell through `Buffer.getChar(atBufferRelative:)` — the one public accessor
    /// that reaches scrollback rows without the internal scroll-invariant offset.
    /// Same wide-glyph / NUL handling as `row(_:cols:)`.
    private func retainedRow(_ bufferRow: Int, cols: Int) -> TerminalRow {
        var cells: [TerminalCell] = []
        cells.reserveCapacity(cols)
        var text = ""
        var i = 0
        while i < cols {
            let cd = terminal.buffer.getChar(atBufferRelative: Position(col: i, row: bufferRow))
            let width = Int(cd.width)
            if width == 0 {
                i += 1
                continue
            }
            let raw = terminal.getCharacter(for: cd)
            let ch: Character = raw == "\u{0}" ? " " : raw
            cells.append(TerminalCell(
                char: ch,
                width: width,
                fg: Self.color(cd.attribute.fg),
                bg: Self.color(cd.attribute.bg),
                style: Self.style(cd.attribute.style)))
            text.append(ch)
            i += 1
        }
        while let last = text.last, last == " " { text.removeLast() }
        return TerminalRow(cells: cells, text: text)
    }

    private static func color(_ c: Attribute.Color) -> TerminalColor {
        switch c {
        case .defaultColor: return .default
        case .defaultInvertedColor: return .defaultInverted
        case .ansi256(let code): return .ansi(code)
        case .trueColor(let r, let g, let b): return .trueColor(r: r, g: g, b: b)
        }
    }

    private static func style(_ s: CharacterStyle) -> TerminalCellStyle {
        var out: TerminalCellStyle = []
        if s.contains(.bold) { out.insert(.bold) }
        if s.contains(.underline) { out.insert(.underline) }
        if s.contains(.blink) { out.insert(.blink) }
        if s.contains(.inverse) { out.insert(.inverse) }
        if s.contains(.invisible) { out.insert(.invisible) }
        if s.contains(.dim) { out.insert(.dim) }
        if s.contains(.italic) { out.insert(.italic) }
        if s.contains(.crossedOut) { out.insert(.crossedOut) }
        return out
    }

    // MARK: - TerminalDelegate

    // Host device-query responses (DA, DSR, cursor reports). Intentionally dropped:
    // this is a read-only mirror; the live view answers these, and answering twice
    // would corrupt the pty input stream.
    public func send(source: Terminal, data: ArraySlice<UInt8>) {}

    public func showCursor(source: Terminal) { lock.withLock { cursorVisible = true } }
    public func hideCursor(source: Terminal) { lock.withLock { cursorVisible = false } }

    public func setTerminalTitle(source: Terminal, title: String) {
        lock.withLock { lastTitle = title }
        for l in lock.withLock({ Array(titleListeners.values) }) { l(title) }
    }
}
