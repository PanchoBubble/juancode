/// How one session-activity transition affects that session's "done-unseen" flag —
/// the sidebar's green check for "the agent finished a turn while you were looking
/// elsewhere" (juancode-t9p). Pure so the edge rules are unit-testable apart from
/// the UI model; the app layer owns the flag set and the selection.
public enum UnseenCompletionEffect: Sendable, Equatable {
    /// The agent completed a turn while the session was not on screen — flag it.
    case set
    /// A new turn started — any lingering "done" is stale, drop it.
    case clear
    /// The transition says nothing about the flag — leave it as it is.
    case none
}

/// Classify an activity transition for the done-unseen flag.
///
/// - `set` only on a *notified* busy → idle edge (a real turn boundary; the
///   detector's `reset()` on session teardown emits the same edge with
///   `notify == false`, which must not flag a killed session as "done") and only
///   when the session isn't the current selection — the user watching a session
///   sees its result land, so there is nothing unseen.
/// - `clear` whenever the agent goes busy again: the working glyph takes over and
///   the previous completion is no longer news.
/// - busy → waitingInput deliberately does NOT set: the amber waiting state is its
///   own, louder, signal and clears by being answered, not by being seen.
public func unseenCompletionEffect(
    prev: SessionActivity?, next: SessionActivity, notify: Bool, isSelected: Bool
) -> UnseenCompletionEffect {
    if next == .busy { return .clear }
    if prev == .busy, next == .idle, notify, !isSelected { return .set }
    return .none
}
