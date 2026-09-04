import Foundation

/// Global pause: put every live session to sleep at once, and bring exactly that
/// set back on play.
///
/// Pause reuses the per-session sleep path (kill the CLI tree, keep the row, its
/// scrollback and its resume id), so the RAM of ~300MB per live session is
/// actually returned — that is the point of the button. The cost is that an
/// in-flight turn is lost: play resumes the conversation with `--resume`, it does
/// not continue mid-thought.
///
/// The paused set has to be recorded separately from `meta.dormant`, which is too
/// broad to resume from: the idle reaper and a graceful quit both set it, so
/// "everything dormant" would sweep sessions the user put to sleep themselves
/// weeks ago back into life on the next play.
public enum GlobalPause {
    /// One session as the pause planner sees it. Deliberately not `SessionMeta` —
    /// what matters is liveness and whether it is a real agent.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let isLive: Bool
        /// Editor/terminal panes are ptys too, but they hold no conversation to
        /// resume: sleeping one loses the buffer and play brings back an empty
        /// shell. They stay running.
        public let isAgent: Bool

        public init(id: String, isLive: Bool, isAgent: Bool) {
            self.id = id
            self.isLive = isLive
            self.isAgent = isAgent
        }
    }

    /// The sessions a pause should sleep, in the given order. Everything live and
    /// agent-backed goes, including the selected one — "pause all" that leaves the
    /// pane you're looking at burning CPU isn't a pause.
    public static func targets(_ candidates: [Candidate]) -> [String] {
        candidates.filter { $0.isLive && $0.isAgent }.map(\.id)
    }

    /// The sessions a play should revive: the recorded paused set, minus anything
    /// that came back on its own (clicked, resumed by the Oracle) or vanished from
    /// the sidebar entirely while paused.
    ///
    /// `focus` is floated to the front so the pane you are looking at is the first
    /// one live rather than whichever row happened to sort first.
    public static func revivals(paused: Set<String>, present: [Candidate],
                                focus: String?) -> [String] {
        let ordered = present.filter { paused.contains($0.id) && !$0.isLive }.map(\.id)
        guard let focus, ordered.contains(focus) else { return ordered }
        return [focus] + ordered.filter { $0 != focus }
    }

    /// Deal ids round-robin into at most `lanes` lanes.
    ///
    /// Each revival is a real `claude --resume` process, so the lane count is what
    /// bounds the RAM and pty burst of a play after a big pause — the same bound
    /// the launch sweep applies for the same reason. Round-robin rather than
    /// contiguous chunks so the head of the list (the focused pane first) starts
    /// early instead of queueing behind a lane's whole share.
    public static func lanes(_ ids: [String], lanes count: Int) -> [[String]] {
        guard !ids.isEmpty, count > 0 else { return [] }
        var out: [[String]] = Array(repeating: [], count: min(count, ids.count))
        for (i, id) in ids.enumerated() { out[i % out.count].append(id) }
        return out
    }
}
