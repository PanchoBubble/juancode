import Foundation

/// Where the sidebar selection lands when the selected session's agent is killed
/// (juancode-x46x).
///
/// A killed session drops out of the live registry, so the pane behind it falls
/// back to re-feeding raw scrollback into a fresh terminal — the CLI's TUI
/// escapes replayed at the wrong grid size, i.e. a wall of mangled text. Handing
/// the pane to a still-running neighbour keeps that off screen; the explicit
/// "stopped" card is only for when nothing else is running.
public enum KilledSessionLanding {
    /// One sidebar row, in on-screen order.
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var cwd: String
        /// Whether its pty is still running.
        public var live: Bool
        /// Editor panes (nvim etc.) are live ptys but not agents — never a landing.
        public var isEditor: Bool

        public init(id: String, cwd: String, live: Bool, isEditor: Bool = false) {
            self.id = id
            self.cwd = cwd
            self.live = live
            self.isEditor = isEditor
        }
    }

    /// The session to select once `killed` dies, or nil to stay put: the nearest
    /// running non-editor row in sidebar order, preferring the killed session's
    /// own folder so a kill keeps you inside the project you were working in.
    /// Ties between a row above and a row below land on the one below, matching
    /// the close-a-session neighbour rule.
    public static func landing(after killed: String, in rows: [Candidate]) -> String? {
        guard let idx = rows.firstIndex(where: { $0.id == killed }) else { return nil }
        let home = rows[idx].cwd
        return rows.enumerated()
            .filter { $0.element.id != killed && $0.element.live && !$0.element.isEditor }
            .min { a, b in
                let homeA = a.element.cwd == home, homeB = b.element.cwd == home
                if homeA != homeB { return homeA }
                let distA = abs(a.offset - idx), distB = abs(b.offset - idx)
                if distA != distB { return distA < distB }
                return a.offset > idx
            }?.element.id
    }

    /// Fallback for when the killed row isn't on screen at all (collapsed folder,
    /// active filter) so `landing` has no anchor to measure from: the first
    /// running non-editor session in the given order.
    public static func anyLive(excluding killed: String, in rows: [Candidate]) -> String? {
        rows.first { $0.id != killed && $0.live && !$0.isEditor }?.id
    }
}
