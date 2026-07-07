import Foundation

/// Pure find-in-scrollback logic (juancode-972): turn a session's raw pty
/// scrollback bytes into plain text lines, then locate query matches within them.
///
/// Why this lives here and not on the terminal surface: neither of juancode's two
/// terminal surfaces exposes a usable search API. libghostty's `TerminalView` /
/// `TerminalSurface` / `InMemoryTerminalSession` have no text-search or
/// programmatic scroll-to-match; SwiftTerm ships a `SearchService` but keeps it
/// internal to the view. So the only text we can reliably search is the data we
/// already own — `Session.getScrollback()`. We strip ANSI here (the escape parser
/// mirrors `TerminalScreen`'s) and index matches so the find bar can show a count,
/// step prev/next, and highlight the current match's line in context.
///
/// Scope note: full-screen TUIs (claude/codex on the alternate screen) repaint in
/// place, so their retained "scrollback" is really the current viewport — this
/// extractor renders that faithfully. Plain-shell (normal-buffer) history strips
/// cleanly across all retained lines.

/// One match within the extracted text. Offsets are `Character` indices so the UI
/// can slice the line into pre/match/post for highlighting without re-searching.
public struct TerminalMatch: Equatable, Sendable {
    /// 0-based index into the extracted lines.
    public let line: Int
    /// 0-based `Character` offset of the match within its line.
    public let start: Int
    /// Match length in `Character`s.
    public let length: Int

    public init(line: Int, start: Int, length: Int) {
        self.line = line
        self.start = start
        self.length = length
    }
}

/// Strips ANSI/control sequences from raw pty bytes into plain text lines. Renders
/// CR as a column reset and BS as cursor-left *within* a line (so `foo\rbar` →
/// `bar`), and breaks lines on LF/VT/FF. Escape sequences (CSI, OSC/DCS/SOS/PM/APC
/// strings, charset designators, single-byte escapes) are removed; SGR colours and
/// absolute cursor moves don't affect the extracted text. Mirrors the escape
/// parsing in `TerminalScreen`.
public enum TerminalTextExtractor {
    /// Extract plain text lines from raw pty scrollback bytes (decoded as UTF-8).
    public static func lines(fromANSI bytes: [UInt8]) -> [String] {
        lines(fromANSI: String(decoding: bytes, as: UTF8.self))
    }

    /// Extract plain text lines from a string still carrying ANSI escape sequences.
    public static func lines(fromANSI text: String) -> [String] {
        var out: [String] = []
        var line: [Character] = []
        var col = 0

        func flush() {
            var end = line.count
            while end > 0, line[end - 1] == " " { end -= 1 }
            out.append(String(line[0..<end]))
            line.removeAll(keepingCapacity: true)
            col = 0
        }
        // Write `c` at the current column, padding with spaces if the column sits
        // past the current end of the line (an absolute-position gap or a tab).
        func put(_ c: Character) {
            if col < line.count {
                line[col] = c
            } else {
                while line.count < col { line.append(" ") }
                line.append(c)
            }
            col += 1
        }

        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var i = 0
        while i < n {
            let c = scalars[i]
            switch c {
            case "\u{1B}":
                i = skipEscape(scalars, i)
            case "\n", "\u{0B}", "\u{0C}": // LF / VT / FF
                flush(); i += 1
            case "\r": // CR
                col = 0; i += 1
            case "\u{08}": // BS
                col = max(0, col - 1); i += 1
            case "\u{09}": // HT — advance to the next 8-col tab stop
                col = ((col / 8) + 1) * 8; i += 1
            default:
                if c.value < 0x20 { i += 1 } // other C0 controls: ignore
                else { put(Character(c)); i += 1 }
            }
        }
        flush() // trailing partial line
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out
    }

    /// Extracted text as a single string, lines joined by "\n".
    public static func text(fromANSI bytes: [UInt8]) -> String {
        lines(fromANSI: bytes).joined(separator: "\n")
    }

    /// Skip the escape sequence starting at `scalars[i]` (== ESC). Returns the index
    /// just past the sequence, or `count` if it runs to the end of input. Mirrors
    /// `TerminalScreen.handleEscape` but only *consumes* — it changes no state.
    private static func skipEscape(_ scalars: [Unicode.Scalar], _ i: Int) -> Int {
        let n = scalars.count
        guard i + 1 < n else { return n }
        switch scalars[i + 1] {
        case "[":
            // CSI: params/intermediates (0x20-0x3F) then a final byte (0x40-0x7E).
            var j = i + 2
            while j < n, scalars[j].value >= 0x20, scalars[j].value <= 0x3F { j += 1 }
            return j < n ? j + 1 : n
        case "]", "P", "X", "^", "_":
            // OSC/DCS/SOS/PM/APC string: runs until ST (ESC \) or BEL.
            var j = i + 2
            while j < n {
                if scalars[j] == "\u{07}" { return j + 1 }
                if scalars[j] == "\u{1B}", j + 1 < n, scalars[j + 1] == "\\" { return j + 2 }
                j += 1
            }
            return n
        case "(", ")", "*", "+":
            return min(i + 3, n) // charset designator: ESC ( <char>
        default:
            return min(i + 2, n) // other 2-byte escapes
        }
    }
}

/// Case-insensitive (by default) substring matching + wrapping navigation over
/// extracted terminal text.
public enum TerminalFind {
    /// All non-overlapping matches of `query` across `lines`, in reading order
    /// (top line first, left-to-right within a line). Empty query ⇒ no matches.
    public static func matches(of query: String, in lines: [String],
                               caseSensitive: Bool = false) -> [TerminalMatch] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var result: [TerminalMatch] = []
        for (idx, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            var from = line.startIndex
            while from < line.endIndex,
                  let range = line.range(of: query, options: options, range: from..<line.endIndex) {
                let start = line.distance(from: line.startIndex, to: range.lowerBound)
                let length = line.distance(from: range.lowerBound, to: range.upperBound)
                result.append(TerminalMatch(line: idx, start: start, length: length))
                // Advance past this match; guard the empty-range case (can't happen
                // with a non-empty query, but keeps the loop provably terminating).
                from = range.upperBound > range.lowerBound ? range.upperBound
                    : line.index(after: range.lowerBound)
            }
        }
        return result
    }

    /// The next match index in `direction`, wrapping around the ends. Returns nil
    /// when there are no matches. With no current selection, forward starts at the
    /// first match and backward at the last.
    public static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        if forward { return (current + 1) % count }
        return (current - 1 + count) % count
    }
}
