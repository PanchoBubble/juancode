import Foundation
import JuancodeCore

/// The redraw a freshly-attached client is handed so its terminal lands on the
/// session's CURRENT screen — the `scrollback` payload of `ServerMessage.attached`
/// (juancode-r5cf).
///
/// It used to be the retained BYTE LOG, replayed verbatim. A byte log is only
/// meaningful at the width it was produced for: it carries hard wraps, absolute
/// cursor moves and screen clears that land in the right cell at that width and
/// nowhere else. Replayed into a client of a different size, every wrapped line
/// lands wrong — the known garbling failure — and there is no width recorded
/// alongside the bytes for anything downstream to correct with. It also replays
/// whatever the log happens to contain: a half-written escape sequence at the ring
/// boundary, a stale alt-screen enter with no matching leave.
///
/// So attach replays from PARSED VT STATE instead, the way `peek` already reads it
/// (juancode-tyd9). Both go through the same reconstruction —
/// `SessionTerminalModel` → `TerminalSeedEncoder` — which is what the local pane's
/// attach seeding has used since juancode-a2h.2; this makes the remote path use it
/// too. What comes out is well-formed by construction and carries the state a byte
/// log only carried by accident: SGR styles, cursor position and visibility, the
/// screen buffer in force, the input modes the program enabled, and the window
/// title it announced.
///
/// The wire shape does not change. `attached.scrollback` is still a string of
/// terminal bytes, so every existing client — the desktop pane, the phone console,
/// the sidecar — renders it with the code it already has.
enum AttachReplay {
    /// A live session: re-encoded straight off its model. The common case, and the
    /// exact screen the CLI drew, because the model parses at the pty's own width
    /// (`Session.resize` moves both in one call, so it cannot mis-wrap).
    ///
    /// Deliberately NOT resized to the attaching client's grid: the pty is shared,
    /// a secondary viewer does not own it (juancode-1th.1), and repainting the
    /// model at a viewer's size would make the next real frame disagree with the
    /// redraw. A client that does own the grid has already resized it by the time
    /// this is called, so it gets its own size anyway.
    static func live(
        _ model: SessionTerminalModel,
        scrollbackRows: Int = SessionTerminalModel.defaultSeedScrollbackRows
    ) -> String {
        String(decoding: model.seedBytes(maxScrollbackRows: scrollbackRows), as: UTF8.self)
    }

    /// A session with no live model — restored after an app restart, or reaped by
    /// the idle reaper. Its stored byte log is all there is, so the log is REPLAYED
    /// HERE, at the grid the store recorded for it, and the resulting state is
    /// re-encoded like any other. The client then receives a redraw instead of a
    /// log, which is what makes it width-stable: hard rows repaint the same at any
    /// size, where the raw log only reads correctly at one.
    ///
    /// `parsedAt` nil means the store has no record of the width (a row written
    /// before the column existed). Replaying at the client's own grid is then the
    /// only available guess — no worse than handing the client the log to parse at
    /// that same width, and still clean, but the wrapping may not be the CLI's.
    static func stored(
        _ bytes: [UInt8],
        parsedAt: (cols: Int, rows: Int)?,
        presentedAt: (cols: Int, rows: Int),
        scrollbackRows: Int = SessionTerminalModel.defaultSeedScrollbackRows
    ) -> String {
        let present = (cols: max(1, presentedAt.cols), rows: max(1, presentedAt.rows))
        let parsed = parsedAt.map { (cols: max(1, $0.cols), rows: max(1, $0.rows)) } ?? present
        let model = SessionTerminalModel.replaying(
            bytes, parsedCols: parsed.cols, parsedRows: parsed.rows,
            scrollbackLines: max(2000, scrollbackRows))
        // Reflow over parsed rows, which is the correction a client re-rendering raw
        // bytes can never make for itself.
        if parsed != present { model.resize(cols: present.cols, rows: present.rows) }
        return live(model, scrollbackRows: scrollbackRows)
    }
}
