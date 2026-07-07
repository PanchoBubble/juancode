import Foundation

/// LRU pool of keep-alive terminal panes (juancode-073).
///
/// Switching sessions used to tear down the live terminal surface and replay raw
/// scrollback on return — bytes recorded at historical widths re-render mis-wrapped
/// (the replay-garble bug class). Instead the app keeps the surfaces of recently
/// viewed live sessions MOUNTED (rendering suspended, pty sizing frozen while
/// hidden) and this pool decides which: MRU-ordered, capped small because every
/// mounted pane holds a Metal surface. An evicted pane falls back to the old
/// teardown+replay path the next time its session is opened.
///
/// Pure bookkeeping — generic over the session object so it can be unit-tested
/// without a live pty. The UI keys each pane's SwiftUI identity by `Entry.id`
/// (session object identity + refresh token), so replacing either recreates that
/// pane; an entry that merely moves in MRU order keeps its mounted view.
public struct LivePanePool<S: AnyObject> {
    public struct Entry: Identifiable {
        public let sessionId: String
        public let session: S
        /// The refresh token at (re)creation. Bumping the visible entry's token
        /// (the Refresh CTA) changes `id`, recreating just that pane — hidden
        /// panes keep the token they mounted with, so a refresh never tears the
        /// whole pool down.
        public var refresh: Int

        public struct ID: Hashable {
            let session: ObjectIdentifier
            let refresh: Int
        }

        public var id: ID { ID(session: ObjectIdentifier(session), refresh: refresh) }
    }

    public private(set) var entries: [Entry] = []
    public let cap: Int

    public init(cap: Int) {
        self.cap = max(1, cap)
    }

    /// The session `id` is now the visible pane. Prunes dead entries, moves (or
    /// creates) its entry at the MRU front — re-keyed if the live session object
    /// changed, since a permissions flip mints a new `Session` behind the same id
    /// and the mounted pane is subscribed to the old one — and evicts past the
    /// cap. `refresh` is only adopted when (re)creating: a pane that merely
    /// becomes visible again keeps its identity, which is the whole point.
    public mutating func noteVisible(_ id: String, refresh: Int, resolve: (String) -> S?) {
        prune(resolve: resolve)
        guard let session = resolve(id) else { return }
        if let idx = entries.firstIndex(where: { $0.sessionId == id }) {
            let existing = entries.remove(at: idx)
            entries.insert(existing.session === session
                            ? existing
                            : Entry(sessionId: id, session: session, refresh: refresh),
                           at: 0)
        } else {
            entries.insert(Entry(sessionId: id, session: session, refresh: refresh), at: 0)
        }
        if entries.count > cap { entries.removeLast(entries.count - cap) }
    }

    /// Drop entries whose session died or was swapped for a new object — the
    /// mounted pane subscribes to the OLD object, so it must unmount rather than
    /// linger hidden holding a dead pty subscription.
    public mutating func prune(resolve: (String) -> S?) {
        entries.removeAll { resolve($0.sessionId) !== $0.session }
    }

    /// Re-key the entry for `id` with a new refresh token: its identity changes,
    /// so the pane is torn down and recreated (re-subscribe with `replay: true`) —
    /// the hard-refresh escape hatch, scoped to one pane.
    public mutating func bumpRefresh(_ id: String, to token: Int) {
        guard let idx = entries.firstIndex(where: { $0.sessionId == id }) else { return }
        entries[idx].refresh = token
    }
}
