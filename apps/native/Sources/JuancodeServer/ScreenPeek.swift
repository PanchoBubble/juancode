import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import JuancodeCore

/// A ONE-SHOT read of a session's rendered screen (juancode-tyd9) — what
/// `GET /api/sessions/:id/screen` answers.
///
/// Until this, the only way out of `SessionTerminalModel` was the `subscribeScreen`
/// stream: a client had to hold a WS open and follow row diffs. Everything that just
/// wants to look once (the oracle sidecar, a Telegram command, a dispatch check-in)
/// therefore read the stored scrollback BYTE LOG instead — and a byte log is the exact
/// input to the garbling failure, because the store records no grid width per row, so
/// bytes parsed at one width get replayed at another and every wrapped line lands in
/// the wrong cell. This reads the already-parsed grid instead: ordered, fully redrawn,
/// width-correct by construction.
///
/// Encoding is deliberately the stream's: `lines` are `ScreenWire` rows, identical
/// frame-for-frame to what a `reset: true` screen frame carries, so one decoder on the
/// client covers both.
///
/// History rows (`?scrollback`) are prepended with NEGATIVE row indices (-n … -1),
/// which keeps the visible rows at exactly the indices the stream uses (0 … rows-1)
/// and leaves no ambiguity about where history ends.
///
/// Best-effort atomicity: the grid and the history tail are two locked reads, so a feed
/// landing between them can scroll one row across the seam. A snapshot of a live pty is
/// approximate by nature; this only matters for the boundary row.
///
/// The WS attach redraw reads the same model for the same reason — see `AttachReplay`,
/// which differs only in encoding it as VT bytes (what a terminal client renders)
/// rather than as styled rows (juancode-r5cf).
struct ScreenPeek {
    let snapshot: TerminalSnapshot
    /// Scrollback history above the visible grid, oldest first. Empty unless asked for.
    let history: [TerminalRow]
    /// The last OSC 0/2 title the program set, if any.
    let title: String?

    init(model: SessionTerminalModel, scrollbackRows: Int) {
        self.history = scrollbackRows > 0 ? model.styledScrollbackTail(scrollbackRows) : []
        self.snapshot = model.snapshot()
        self.title = model.terminalTitle
    }

    /// The default text form: history (when asked for) above the visible screen, rows
    /// joined by "\n" with trailing blank rows dropped.
    var text: String {
        let visible = snapshot.text
        guard !history.isEmpty else { return visible }
        let past = history.map(\.text).joined(separator: "\n")
        return visible.isEmpty ? past : past + "\n" + visible
    }

    /// Styled rows in the stream's own encoding: history at -n … -1, screen at 0 … rows-1.
    var lines: [ScreenRowWire] {
        var out: [ScreenRowWire] = []
        out.reserveCapacity(history.count + snapshot.lines.count)
        for (i, row) in history.enumerated() {
            out.append(ScreenRowWire(row: i - history.count, segs: ScreenWire.segments(row)))
        }
        out.append(contentsOf: ScreenWire.fullLines(snapshot))
        return out
    }

    func wire(sessionId: String) -> ScreenSnapshotWire {
        ScreenSnapshotWire(
            sessionId: sessionId, cols: snapshot.cols, rows: snapshot.rows,
            cursor: ScreenCursorWire(x: snapshot.cursorX, y: snapshot.cursorY,
                                     visible: snapshot.cursorVisible),
            alt: snapshot.isAlternateBuffer, title: title,
            scrollback: history.count, lines: lines)
    }

    /// `?scrollback` / `=1` / `=true` → the seed default cap; `?scrollback=N` (N > 1) →
    /// that many history rows; absent, `=0` or `=false` → none. A boolean flag like
    /// boo's `--scrollback`, with a row count as the refinement.
    static func scrollbackRows(_ raw: String?, cap: Int = 5000) -> Int {
        guard let raw else { return 0 }
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "0" || v == "false" || v == "no" { return 0 }
        if let n = Int(v), n > 1 { return min(n, cap) }
        return SessionTerminalModel.defaultSeedScrollbackRows
    }

    /// Present-means-true, the way `?json` reads, with an explicit `0`/`false` honoured.
    static func flag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !(v == "0" || v == "false" || v == "no")
    }
}

/// `?json=1` body. `lines` is the stream's shape; `rows` stays the GRID HEIGHT, as in a
/// `screen` frame, rather than doubling as the row array.
struct ScreenSnapshotWire: Encodable, Sendable {
    var sessionId: String
    var cols: Int
    var rows: Int
    var cursor: ScreenCursorWire
    var alt: Bool
    var title: String?
    /// How many of `lines` are history rows (all of them at negative indices).
    var scrollback: Int
    var lines: [ScreenRowWire]
}

struct ScreenCursorWire: Encodable, Sendable {
    var x: Int
    var y: Int
    var visible: Bool
}

/// A `text/plain` body — the screen as a human reads it, the endpoint's default.
func textResponse(_ text: String, status: HTTPResponse.Status = .ok) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "text/plain; charset=utf-8"
    return Response(status: status, headers: headers,
                    body: .init(byteBuffer: ByteBuffer(bytes: Array(text.utf8))))
}
