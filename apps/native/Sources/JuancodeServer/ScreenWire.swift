import Foundation
import JuancodeCore

/// Wire shapes for the rendered-screen stream (`ServerMessage.screen`): styled rows
/// as they travel, so a remote client renders the grid without running a terminal
/// emulator. Mirrored in the sidecar's `native-events.ts` (`ScreenSegment` /
/// `ScreenRowUpdate` / `ScreenFrame`) — keep both sides in sync.
///
/// The PROJECTION that built these out of a `SessionTerminalModel` went with the
/// Swift core (juancode-nqpm): the daemon does it now, and the app's `/ws` relay
/// forwards the frames it produces. What is left is the shape `WireProtocol`
/// encodes, which is the contract itself.

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
