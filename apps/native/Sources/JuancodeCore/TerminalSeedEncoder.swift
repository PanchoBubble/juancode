import Foundation

/// Builds a clean VT byte stream that repaints a terminal's visible screen from
/// parsed `TerminalRow`s (juancode-a2h.2). Used by `SessionTerminalModel.seedBytes()`
/// to seed a freshly-attached view without replaying raw pty bytes — the output is
/// well-formed by construction (no partial escapes, no stale alt-screen frames), so
/// the seeded view lands the correct screen with no replay-garble.
///
/// Each row is painted at an absolute position (CUP) so nothing scrolls, and SGR is
/// re-emitted only when a cell's attributes differ from the previous cell (reset to
/// default at the start of every row).
struct TerminalSeedEncoder {
    private(set) var bytes: [UInt8] = []
    private let esc: UInt8 = 0x1B

    private mutating func csi(_ s: String) {
        bytes.append(esc)
        bytes.append(UInt8(ascii: "["))
        bytes.append(contentsOf: s.utf8)
    }

    /// Reset all SGR attributes.
    mutating func reset() { csi("0m") }

    /// Switch to the alternate or normal screen buffer (matching the model's state)
    /// so a full-screen TUI's screen mode is reproduced before painting.
    mutating func setAlternateBuffer(_ alt: Bool) { csi(alt ? "?1049h" : "?1049l") }

    /// Home the cursor and clear the visible screen (scrollback untouched).
    mutating func clearScreen() { csi("H"); csi("2J") }

    /// Paint one visible row at absolute row `r` (0-based), column 1. Coalesces runs
    /// of same-attribute cells into a single SGR. Trailing blank default-styled cells
    /// are dropped (the screen was already cleared), so a mostly-empty row stays cheap.
    mutating func paintRow(_ r: Int, _ row: TerminalRow) {
        csi("\(r + 1);1H")
        // Drop trailing cells that are a plain space with default attributes: the
        // clear already blanked them, and emitting them would just pad the line.
        var end = row.cells.count
        while end > 0, row.cells[end - 1].isBlankDefault { end -= 1 }
        guard end > 0 else { return }
        var current: CellAttrs? = nil
        for i in 0..<end {
            let cell = row.cells[i]
            let attrs = CellAttrs(cell)
            if attrs != current {
                csi(attrs.sgr)
                current = attrs
            }
            bytes.append(contentsOf: String(cell.char).utf8)
        }
        csi("0m")
    }

    /// Position the cursor at (x, y), 0-based, converting to 1-based CUP.
    mutating func moveCursor(x: Int, y: Int) { csi("\(y + 1);\(x + 1)H") }

    mutating func setCursorVisible(_ visible: Bool) { csi(visible ? "?25h" : "?25l") }
}

/// The SGR-relevant attributes of a cell, so a run of identical-looking cells emits
/// one SGR sequence. Rebuilds the full sequence from a reset each change (small,
/// and avoids tracking incremental SGR state).
private struct CellAttrs: Equatable {
    let fg: TerminalColor
    let bg: TerminalColor
    let style: TerminalCellStyle

    init(_ cell: TerminalCell) {
        self.fg = cell.fg
        self.bg = cell.bg
        self.style = cell.style
    }

    /// The `ESC[…m` parameter list (without the leading `ESC[` or trailing `m`),
    /// always starting from `0` (reset) so it is self-contained.
    var sgr: String {
        var p: [String] = ["0"]
        if style.contains(.bold) { p.append("1") }
        if style.contains(.dim) { p.append("2") }
        if style.contains(.italic) { p.append("3") }
        if style.contains(.underline) { p.append("4") }
        if style.contains(.blink) { p.append("5") }
        if style.contains(.inverse) { p.append("7") }
        if style.contains(.invisible) { p.append("8") }
        if style.contains(.crossedOut) { p.append("9") }
        p.append(contentsOf: Self.colorParams(fg, foreground: true))
        p.append(contentsOf: Self.colorParams(bg, foreground: false))
        return p.joined(separator: ";") + "m"
    }

    private static func colorParams(_ c: TerminalColor, foreground: Bool) -> [String] {
        switch c {
        case .default, .defaultInverted:
            return [] // 0-reset already left it at the default fg/bg
        case .ansi(let n):
            if n < 8 { return ["\(Int(n) + (foreground ? 30 : 40))"] }
            if n < 16 { return ["\(Int(n) - 8 + (foreground ? 90 : 100))"] }
            return [foreground ? "38" : "48", "5", "\(n)"]
        case .trueColor(let r, let g, let b):
            return [foreground ? "38" : "48", "2", "\(r)", "\(g)", "\(b)"]
        }
    }
}

private extension TerminalCell {
    /// A plain space with no color/style — safe to drop from a trailing run because
    /// the screen was cleared to exactly this before painting.
    var isBlankDefault: Bool {
        char == " " && style.isEmpty
            && (fg == .default || fg == .defaultInverted)
            && (bg == .default || bg == .defaultInverted)
    }
}
