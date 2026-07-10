/// How a single `SessionMeta` change (the per-session title/usage poll, a rename,
/// an archive) should update the sidebar's `sessions` array (juancode-5qw.8).
///
/// The 4s title/usage poll fires for every running session; routing each tick
/// through a full `store.list()` rebuild re-derives (and re-groups/re-sorts) the
/// whole list every few seconds. When the changed session is one we already hold,
/// patch that one element in place instead — SwiftUI then re-renders only its row.
/// A full rebuild stays reserved for create/exit/adopt (an id we don't have yet).
///
/// Pure so the decision is unit-testable off the main actor, apart from the app
/// model that owns the array and the store.
public enum MetaPatchOutcome: Sendable, Equatable {
    /// Replace the element at `index` with the new meta — no `store.list()` hit.
    case patch(index: Int)
    /// The changed session isn't in the current list yet (an unseen create/adopt);
    /// fall back to a full `refresh()`.
    case fullRefresh
    /// The new meta is byte-for-byte what we already hold — nothing to do (skip the
    /// write so SwiftUI doesn't even re-render the row).
    case noChange
}

/// Decide how a `SessionMeta` change should be applied to `sessions` without a
/// full `store.list()` rebuild. Matches by id; `patch` only when the meta actually
/// differs from the one held (so an unchanged poll is a no-op).
public func metaPatchOutcome(for meta: SessionMeta, in sessions: [SessionMeta]) -> MetaPatchOutcome {
    guard let idx = sessions.firstIndex(where: { $0.id == meta.id }) else {
        return .fullRefresh
    }
    return sessions[idx] == meta ? .noChange : .patch(index: idx)
}
