import Foundation

/// What the toolbar's running-sessions badge counts and lists: the live agents,
/// ordered so the ones actually doing something come first.
///
/// The ordering lives here rather than in the view because it is the only thing
/// about that popover worth being sure of — the list is the one place an agent can
/// be killed without first finding its row, so "working" must never sort below
/// "idle" and push a busy session off the bottom of a long list.
public enum RunningSessions {
    /// One live agent as the badge sees it. Deliberately not `SessionMeta`: the
    /// popover needs liveness (already filtered), what the agent is doing, and
    /// enough to label the row.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let activity: SessionActivity?

        public init(id: String, activity: SessionActivity?) {
            self.id = id
            self.activity = activity
        }
    }

    /// Working first, then waiting on you, then resting. Stable within a bucket, so
    /// the rows keep the sidebar's order instead of shuffling on every activity
    /// edge — a list whose rows move under the pointer is a list that kills the
    /// wrong session.
    public static func order(_ rows: [Row]) -> [Row] {
        rows.enumerated()
            .sorted { a, b in
                let ra = rank(a.element.activity), rb = rank(b.element.activity)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    private static func rank(_ activity: SessionActivity?) -> Int {
        switch activity {
        case .busy: return 0
        case .waitingInput: return 1
        case .idle, nil: return 2
        }
    }
}
