import Foundation

/// What the toolbar's waiting-input badge counts and lists: the live agents sitting
/// on a question, a choice or a permission prompt, longest-waiting first.
///
/// A pure projection so the model can store its result and publish only on a real
/// change: the toolbar must not re-render on every activity edge (juancode-2n0), and
/// only entering or leaving `.waitingInput` moves this list.
public enum WaitingSessions {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        /// When the session entered `.waitingInput`, or nil if the edge predates
        /// this launch's bookkeeping.
        public let since: Date?

        public init(id: String, since: Date?) {
            self.id = id
            self.since = since
        }
    }

    /// The pausable live agents (`GlobalPause.targets`, so editor panes, external
    /// rows and sleeping ones never count) whose activity is `.waitingInput`.
    /// Longest wait first; a missing timestamp sorts last; ties keep `candidates`
    /// order so rows do not shuffle under the pointer.
    public static func project(_ candidates: [GlobalPause.Candidate],
                               activities: [String: SessionActivity],
                               since: [String: Date]) -> [Entry] {
        GlobalPause.targets(candidates)
            .filter { activities[$0] == .waitingInput }
            .enumerated()
            .map { (offset: $0.offset, entry: Entry(id: $0.element, since: since[$0.element])) }
            .sorted { a, b in
                switch (a.entry.since, b.entry.since) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.offset < b.offset
                }
            }
            .map(\.entry)
    }

    /// "12s", "4m", "2h", "3d": how long a row has been waiting, at badge size.
    public static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
