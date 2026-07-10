import Foundation
import JuancodeCore

/// Wire shapes for the rendered-screen stream (`ServerMessage.screen`): styled rows
/// projected straight out of `SessionTerminalModel` so a remote client renders the
/// grid without running a terminal emulator. Mirrored in the sidecar's
/// `native-events.ts` (`ScreenSegment` / `ScreenRowUpdate` / `ScreenFrame`) — keep
/// both sides in sync.

/// One styled run of a row: consecutive cells sharing fg/bg/style collapse into a
/// single segment, so a mostly-uniform row costs a few segments instead of a cell
/// array. Colors encode compactly on the wire: an ANSI-256 index as a number, a
/// truecolor as "#rrggbb", default-inverted as "inv", and the default color is
/// omitted entirely. `st` is the `TerminalCellStyle` bitmask, omitted when plain.
public struct ScreenSegmentWire: Encodable, Equatable, Sendable {
    public var text: String
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var style: TerminalCellStyle

    public init(text: String, fg: TerminalColor, bg: TerminalColor, style: TerminalCellStyle) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.style = style
    }

    private enum K: String, CodingKey { case text, fg, bg, st }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(text, forKey: .text)
        try Self.encodeColor(fg, forKey: .fg, into: &c)
        try Self.encodeColor(bg, forKey: .bg, into: &c)
        if !style.isEmpty { try c.encode(style.rawValue, forKey: .st) }
    }

    private static func encodeColor(
        _ color: TerminalColor, forKey key: K, into c: inout KeyedEncodingContainer<K>
    ) throws {
        switch color {
        case .default:
            break
        case .defaultInverted:
            try c.encode("inv", forKey: key)
        case .ansi(let code):
            try c.encode(Int(code), forKey: key)
        case .trueColor(let r, let g, let b):
            try c.encode(String(format: "#%02x%02x%02x", r, g, b), forKey: key)
        }
    }
}

/// One row of a `screen` frame: its index in the visible grid plus its segments.
/// An empty `segs` means the row is blank.
public struct ScreenRowWire: Encodable, Equatable, Sendable {
    public var row: Int
    public var segs: [ScreenSegmentWire]

    public init(row: Int, segs: [ScreenSegmentWire]) {
        self.row = row
        self.segs = segs
    }
}

enum ScreenWire {
    /// Compress a styled model row into wire segments. Trailing blanks with nothing
    /// visible (no background, no decoration — a blank's fg never shows) are
    /// dropped so an 80-col row of prompt text doesn't ship 70 trailing spaces.
    static func segments(_ row: TerminalRow) -> [ScreenSegmentWire] {
        var cells = row.cells[...]
        while let last = cells.last, last.char == " ", last.bg == .default, last.style.isEmpty {
            cells = cells.dropLast()
        }
        var segs: [ScreenSegmentWire] = []
        for cell in cells {
            if var last = segs.last, last.fg == cell.fg, last.bg == cell.bg, last.style == cell.style {
                last.text.append(cell.char)
                segs[segs.count - 1] = last
            } else {
                segs.append(ScreenSegmentWire(
                    text: String(cell.char), fg: cell.fg, bg: cell.bg, style: cell.style))
            }
        }
        return segs
    }

    /// Every visible row of a snapshot — the `reset: true` payload.
    static func fullLines(_ snapshot: TerminalSnapshot) -> [ScreenRowWire] {
        snapshot.lines.enumerated().map { ScreenRowWire(row: $0.offset, segs: segments($0.element)) }
    }

    /// Only the rows that differ between two same-geometry snapshots — the
    /// `reset: false` payload. Callers repaint wholesale on a geometry change, so
    /// a row present in one snapshot but not the other also counts as changed.
    static func changedLines(prev: TerminalSnapshot, next: TerminalSnapshot) -> [ScreenRowWire] {
        var out: [ScreenRowWire] = []
        for r in 0..<max(prev.lines.count, next.lines.count) {
            let old = r < prev.lines.count ? prev.lines[r] : nil
            let new = r < next.lines.count ? next.lines[r] : nil
            guard old != new else { continue }
            out.append(ScreenRowWire(row: r, segs: new.map(segments) ?? []))
        }
        return out
    }
}
