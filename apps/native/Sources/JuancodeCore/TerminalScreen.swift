import Foundation

/// A tiny *headless* VT screen model — just enough of a terminal emulator to
/// reconstruct what is currently rendered on the screen, so callers can read the
/// actual bottom rows instead of guessing from a flattened byte tail. It does
/// **not** render anything (that's SwiftTerm's job in the UI layer); it only
/// tracks the cell grid, cursor, erases, scrolling, and the alternate screen.
///
/// Why this exists: `claude`/`codex` paint their "esc to interrupt" footer once
/// per turn and then only animate the timer digits via cursor moves — the phrase
/// is never re-emitted. A concatenated, ANSI-stripped tail therefore can't answer
/// "is the footer still on screen *right now*?", which is exactly what determines
/// the session status. A grid model can: the footer occupies real cells until the
/// CLI erases them at turn end. See `ActivityDetector`.
///
/// Scope: both CLIs are full-screen TUIs on the terminal's *alternate* buffer
/// (see `Scrollback.scanAlternate`), so all the interesting content lands in a
/// fixed `cols × rows` grid addressed with absolute cursor moves and line erases —
/// which is the slice of VT we implement. Wide/combining glyphs are approximated
/// as one cell each; we match *text content*, not pixel layout, so that's fine.
///
/// Not thread-safe on its own; `ActivityDetector` owns one and only touches it
/// from its serial queue. Mirrors `apps/server/src/terminalScreen.ts`.
public final class TerminalScreen {
    private final class Buffer {
        var grid: [[Character]]
        var row = 0
        var col = 0
        var savedRow = 0
        var savedCol = 0
        init(width: Int, height: Int) {
            grid = Array(repeating: Array(repeating: " ", count: width), count: height)
        }
    }

    private var width: Int
    private var height: Int
    private var main: Buffer
    private var alt: Buffer
    private var usingAlt = false
    private var autowrap = true
    /// Trailing bytes of an escape sequence split across a `feed` boundary; pty
    /// chunks split anywhere, and an un-buffered split is exactly what defeats a
    /// naive regex. Prepended to the next feed.
    private var pending = ""

    public init(cols: Int, rows: Int) {
        self.width = max(1, cols)
        self.height = max(1, rows)
        self.main = Buffer(width: width, height: height)
        self.alt = Buffer(width: width, height: height)
    }

    private var buf: Buffer { usingAlt ? alt : main }

    // MARK: - public surface

    /// Feed a chunk of decoded pty output, updating the grid.
    public func feed(_ s: String) {
        guard !s.isEmpty || !pending.isEmpty else { return }
        // Iterate Unicode *scalars*, not Characters: Swift folds "\r\n" into a single
        // grapheme-cluster Character, which would hide the CR from control handling.
        let scalars = Array((pending + s).unicodeScalars)
        pending = ""
        process(scalars)
    }

    /// Resize the grid, preserving overlapping content best-effort.
    public func resize(cols: Int, rows: Int) {
        let w = max(1, cols), h = max(1, rows)
        if w == width && h == height { return }
        main = resized(main, w: w, h: h)
        alt = resized(alt, w: w, h: h)
        width = w
        height = h
    }

    /// The active buffer as text: rows joined by "\n", trailing spaces trimmed per
    /// row, and trailing blank rows dropped.
    public var visibleText: String {
        let rows = buf.grid.map { rowString($0) }
        var end = rows.count
        while end > 0, rows[end - 1].isEmpty { end -= 1 }
        return rows[0..<end].joined(separator: "\n")
    }

    /// The last `n` rows of the active buffer as text (the footer / prompt region).
    public func bottomText(_ n: Int) -> String {
        let rows = buf.grid.suffix(max(0, n)).map { rowString($0) }
        return rows.joined(separator: "\n")
    }

    // MARK: - parser

    private func process(_ scalars: [Unicode.Scalar]) {
        var i = 0
        let n = scalars.count
        while i < n {
            let c = scalars[i]
            if c == "\u{1B}" {
                guard let consumed = handleEscape(scalars, i) else {
                    // Incomplete escape at end of feed — stash and resume next time.
                    pending = String(String.UnicodeScalarView(scalars[i...]))
                    return
                }
                i = consumed
            } else if c.value < 0x20 {
                handleControl(c.value)
                i += 1
            } else {
                putChar(Character(c))
                i += 1
            }
        }
    }

    /// Handle an escape sequence starting at `scalars[i]` (== ESC). Returns the index
    /// just past the sequence, or nil if the sequence is incomplete (needs more
    /// input). Mirrors the TS `handleEscape`.
    private func handleEscape(_ scalars: [Unicode.Scalar], _ i: Int) -> Int? {
        let n = scalars.count
        guard i + 1 < n else { return nil }
        let kind = scalars[i + 1]
        switch kind {
        case "[":
            // CSI: params/intermediates (0x20-0x3F) then a final byte (0x40-0x7E).
            var j = i + 2
            while j < n, scalars[j].value >= 0x20, scalars[j].value <= 0x3F { j += 1 }
            guard j < n else { return nil }
            let final = Character(scalars[j])
            let params = String(String.UnicodeScalarView(scalars[(i + 2)..<j]))
            handleCSI(params: params, final: final)
            return j + 1
        case "]", "P", "X", "^", "_":
            // OSC/DCS/SOS/PM/APC string: runs until ST (ESC \) or BEL.
            var j = i + 2
            while j < n {
                if scalars[j] == "\u{07}" { return j + 1 }
                if scalars[j] == "\u{1B}" {
                    guard j + 1 < n else { return nil } // maybe ESC \, need more
                    if scalars[j + 1] == "\\" { return j + 2 }
                }
                j += 1
            }
            return nil // unterminated string — wait for more
        case "(", ")", "*", "+":
            // Charset designator: ESC ( <one char>. Ignore, but consume the arg.
            guard i + 2 < n else { return nil }
            return i + 3
        case "7": buf.savedRow = buf.row; buf.savedCol = buf.col; return i + 2
        case "8": buf.row = buf.savedRow; buf.col = buf.savedCol; return i + 2
        case "M": reverseIndex(); return i + 2
        case "=", ">", "c": return i + 2 // keypad modes / RIS-ish — ignore arg
        default: return i + 2 // unknown 2-byte escape — skip
        }
    }

    private func handleControl(_ v: UInt32) {
        switch v {
        case 0x0D: buf.col = 0                                   // CR
        case 0x0A, 0x0B, 0x0C: lineFeed()                        // LF/VT/FF
        case 0x08: buf.col = max(0, buf.col - 1)                 // BS
        case 0x09:                                               // HT
            buf.col = min(width - 1, ((buf.col / 8) + 1) * 8)
        default: break                                           // BEL etc.
        }
    }

    private func handleCSI(params raw: String, final: Character) {
        let isPrivate = raw.first == "?"
        let nums = raw.drop { $0 == "?" || $0 == ">" || $0 == "!" }
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        func p(_ idx: Int, _ def: Int) -> Int { idx < nums.count ? (nums[idx] ?? def) : def }

        switch final {
        case "A": buf.row = max(0, buf.row - max(1, p(0, 1)))
        case "B", "e": buf.row = min(height - 1, buf.row + max(1, p(0, 1)))
        case "C", "a": buf.col = min(width - 1, buf.col + max(1, p(0, 1)))
        case "D": buf.col = max(0, buf.col - max(1, p(0, 1)))
        case "E": buf.row = min(height - 1, buf.row + max(1, p(0, 1))); buf.col = 0
        case "F": buf.row = max(0, buf.row - max(1, p(0, 1))); buf.col = 0
        case "G", "`": buf.col = clampCol(p(0, 1) - 1)
        case "d": buf.row = clampRow(p(0, 1) - 1)
        case "H", "f": buf.row = clampRow(p(0, 1) - 1); buf.col = clampCol(p(1, 1) - 1)
        case "J": eraseInDisplay(p(0, 0))
        case "K": eraseInLine(p(0, 0))
        case "S": scrollUp(max(1, p(0, 1)))
        case "T": scrollDown(max(1, p(0, 1)))
        case "s": buf.savedRow = buf.row; buf.savedCol = buf.col
        case "u": buf.row = buf.savedRow; buf.col = buf.savedCol
        case "h", "l": if isPrivate { setPrivateMode(nums, enable: final == "h") }
        default: break // SGR (m), DECSTBM (r), and the rest don't affect text content
        }
    }

    private func setPrivateMode(_ nums: [Int?], enable: Bool) {
        for case let v? in nums {
            switch v {
            case 1049, 1047, 47:
                if enable {
                    if !usingAlt { usingAlt = true; clearBuffer(alt); alt.row = 0; alt.col = 0 }
                } else if usingAlt {
                    usingAlt = false
                }
            case 7: autowrap = enable
            default: break
            }
        }
    }

    // MARK: - grid primitives

    private func putChar(_ c: Character) {
        if buf.col >= width {
            if autowrap { buf.col = 0; lineFeed() } else { buf.col = width - 1 }
        }
        let r = clampRow(buf.row), col = clampCol(buf.col)
        buf.grid[r][col] = c
        buf.col += 1
    }

    private func lineFeed() {
        if buf.row >= height - 1 { scrollUp(1) } else { buf.row += 1 }
    }

    private func reverseIndex() {
        if buf.row <= 0 { scrollDown(1) } else { buf.row -= 1 }
    }

    private func scrollUp(_ n: Int) {
        let k = min(n, height)
        buf.grid.removeFirst(k)
        buf.grid.append(contentsOf: (0..<k).map { _ in blankRow() })
    }

    private func scrollDown(_ n: Int) {
        let k = min(n, height)
        buf.grid.removeLast(k)
        buf.grid.insert(contentsOf: (0..<k).map { _ in blankRow() }, at: 0)
    }

    private func eraseInLine(_ mode: Int) {
        let r = clampRow(buf.row)
        switch mode {
        case 1: for c in 0...clampCol(buf.col) { buf.grid[r][c] = " " }       // start→cursor
        case 2: buf.grid[r] = blankRow()                                      // whole line
        default: for c in clampCol(buf.col)..<width { buf.grid[r][c] = " " }  // cursor→end
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        let r = clampRow(buf.row)
        switch mode {
        case 1: // start of screen → cursor
            for rr in 0..<r { buf.grid[rr] = blankRow() }
            for c in 0...clampCol(buf.col) { buf.grid[r][c] = " " }
        case 2, 3: // entire screen
            for rr in 0..<height { buf.grid[rr] = blankRow() }
        default: // cursor → end of screen
            for c in clampCol(buf.col)..<width { buf.grid[r][c] = " " }
            for rr in (r + 1)..<height { buf.grid[rr] = blankRow() }
        }
    }

    // MARK: - helpers

    private func blankRow() -> [Character] { Array(repeating: " ", count: width) }
    private func clampRow(_ r: Int) -> Int { min(max(0, r), height - 1) }
    private func clampCol(_ c: Int) -> Int { min(max(0, c), width - 1) }

    private func rowString(_ row: [Character]) -> String {
        var end = row.count
        while end > 0, row[end - 1] == " " { end -= 1 }
        return String(row[0..<end])
    }

    private func clearBuffer(_ b: Buffer) {
        for r in 0..<height { b.grid[r] = blankRow() }
    }

    private func resized(_ b: Buffer, w: Int, h: Int) -> Buffer {
        let out = Buffer(width: w, height: h)
        for r in 0..<min(h, b.grid.count) {
            for c in 0..<min(w, b.grid[r].count) { out.grid[r][c] = b.grid[r][c] }
        }
        out.row = min(b.row, h - 1)
        out.col = min(b.col, w - 1)
        return out
    }
}
