/// Whether one session-activity transition should raise an OS notification, and of
/// which kind (juancode-bao). Pure so the edge rules are unit-testable apart from
/// `UNUserNotificationCenter`; the app layer owns authorization + delivery + the
/// click-through selection. Mirrors the style of `unseenCompletionEffect` — the
/// sidebar's green-check derivation runs on the very same edges (see
/// [[UnseenCompletion.swift]]), so this does not re-derive the edge, it classifies it.
public enum AgentNotificationKind: Sendable, Equatable {
    /// The agent finished a turn (busy → idle) — informational, one-shot.
    case turnFinished
    /// The agent is now blocked on you (a settled input/permission prompt) —
    /// louder; the turn cannot continue until you answer.
    case waitingForInput
}

/// Classify an activity transition for a background-session OS notification.
///
/// - Only *notified* edges qualify: the detector's teardown `reset()` re-emits
///   busy → idle with `notify == false`, which must never ding a killed session.
/// - The one session you are actively watching (app frontmost **and** that session
///   selected) is never a surprise, so it is suppressed — matching the Dock-bounce
///   rule in `AppModel.notifyTurnEnd`. A hidden/background session notifies even
///   while the app is frontmost (you are looking at a *different* pane), and any
///   session notifies while the app is inactive.
/// - `waitingForInput` fires on *any* settle into the waiting state (busy → waiting
///   at turn end, or idle → waiting for a resumed pending prompt). Under an
///   accept-all (skip-permissions) session the detector's auto-approved prompts
///   never settle into `waitingInput`, so no waiting notification is produced for
///   them — nothing extra to suppress here.
/// - `turnFinished` fires only on the busy → idle boundary (a real turn end).
public func agentNotificationEffect(
    prev: SessionActivity?, next: SessionActivity, notify: Bool,
    isSelected: Bool, appActive: Bool
) -> AgentNotificationKind? {
    guard notify else { return nil }
    if isSelected, appActive { return nil }
    if next == .waitingInput { return .waitingForInput }
    if prev == .busy, next == .idle { return .turnFinished }
    return nil
}
