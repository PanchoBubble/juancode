import Foundation

/// What a cold launch should bring back after a crash or a quit (juancode restore).
///
/// The app already persists every session and keeps the ones that were live surfaced
/// as resumable "sleeping" rows; what it never did was come back to where you were.
/// This decides that, and deliberately decides only that — the plan revives ONE pane.
/// Reviving every previously-live session would spawn N real `claude --resume`
/// processes at launch, which is both the RAM spike we don't want and the exact pty
/// path most of the crashes come from. The rest stay one click from live, and the
/// existing `openPersistedPane` revive handles them lazily when you look at them.
///
/// Pure so the launch decision is testable without a registry, a store, or a pty.
public struct SessionRestorePlan: Equatable, Sendable {
    /// The single session to reopen and revive now, or nil when nothing qualifies.
    public let focus: String?
    /// Every previously-live session worth surfacing as restored, most-recently-updated
    /// first, `focus` included. These are rows, not spawns.
    public let reopen: [String]
    /// The subset of `reopen` whose agent was mid-turn when the process died, so the
    /// UI can offer to continue that work (see `SessionContinueOffer`).
    public let midTurn: Set<String>

    public init(focus: String?, reopen: [String], midTurn: Set<String>) {
        self.focus = focus
        self.reopen = reopen
        self.midTurn = midTurn
    }

    /// Nothing to restore.
    public static let empty = SessionRestorePlan(focus: nil, reopen: [], midTurn: [])

    /// Build the plan.
    ///
    /// - `previouslyLive`: ids whose pty was alive when the last process ended — crash
    ///   orphans (`markOrphansDormant`) plus the sessions slept on a graceful quit.
    /// - `metas`: the persisted rows. Ids absent here (deleted, or dropped by the
    ///   retention cap) and archived rows are ignored; a row you filed away shouldn't
    ///   come back just because it happened to be open.
    /// - `lastFocused`: the pane you were looking at, if it's still restorable. Falls
    ///   back to the most recently updated previously-live session, which is what you
    ///   were most likely watching — this is the crash path, where the last-focused
    ///   marker is the one thing that may not have reached disk.
    /// - `midTurnIds`: the durable busy markers (`PersistentStore.takeMidTurnIds`),
    ///   narrowed to sessions actually being restored.
    public static func make(previouslyLive: Set<String>,
                            metas: [SessionMeta],
                            lastFocused: String?,
                            midTurnIds: Set<String>) -> SessionRestorePlan {
        let restorable = metas.filter { previouslyLive.contains($0.id) && !$0.archived }
        guard !restorable.isEmpty else { return .empty }
        let reopen = restorable.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        let ids = Set(reopen)
        let focus = lastFocused.flatMap { ids.contains($0) ? $0 : nil } ?? reopen.first
        return SessionRestorePlan(focus: focus, reopen: reopen,
                                  midTurn: midTurnIds.intersection(ids))
    }
}

/// Whether a restored pane should offer "Continue" — the optional nudge for a session
/// whose agent was working when the app died (juancode restore).
///
/// Kept pure and separate from `SessionRestoredBanner`: that banner explains the
/// replay and auto-dismisses, while this offer is a user action that must survive
/// until it's taken or dismissed.
public enum SessionContinueOffer {
    /// The offer is shown when the session was mid-turn at death, its pty is back, and
    /// the resumed CLI is NOT already working — a resume that picked the turn up on its
    /// own needs no nudge, and pushing "continue" into a busy composer would queue a
    /// stray turn. `handled` covers both "already continued" and "dismissed", so the
    /// offer never comes back for the same restore.
    public static func shouldOffer(wasMidTurn: Bool,
                                   isLive: Bool,
                                   activity: SessionActivity?,
                                   handled: Bool) -> Bool {
        guard wasMidTurn, isLive, !handled else { return false }
        return activity != .busy
    }

    /// What gets typed into the revived CLI. Plain and boring on purpose: it reads as a
    /// human nudge in the transcript rather than a synthetic instruction, and every
    /// agent CLI understands it.
    public static let prompt = "continue"
}
