import Foundation

/// Outbound notification routing (juancode-xac): builds the JSON body POSTed to a
/// user-configured webhook when a session finishes a turn or starts waiting for
/// input, so background work reaches the user off-device. The body is
/// Slack-incoming-webhook-compatible (a top-level `text`) *and* carries structured
/// fields (`event`, `title`, `sessionId`, `cwd`) for generic consumers — so one
/// URL covers Slack, Discord-compatible relays, and custom endpoints alike.
///
/// Pure and dependency-free (just Foundation's JSON) so it's unit-testable without
/// a network; the actual POST lives in `AppModel`.

public enum NotificationEvent: String, Sendable, Equatable {
    /// The agent stopped to ask a question / permission — blocked on the user.
    case waitingInput = "waiting_input"
    /// A turn simply finished.
    case turnEnd = "turn_end"
}

/// The human-readable one-liner (the Slack `text`).
public func notificationText(event: NotificationEvent, title: String) -> String {
    let name = title.isEmpty ? "A session" : title
    switch event {
    case .waitingInput: return "⏳ \(name) needs your input"
    case .turnEnd: return "✅ \(name) finished a turn"
    }
}

/// The JSON POST body for the webhook. Slack reads `text`; generic consumers read
/// the structured fields. Stable key set so consumers can rely on it. Pure.
public func webhookBody(event: NotificationEvent, title: String, sessionId: String, cwd: String) -> Data {
    let obj: [String: String] = [
        "text": notificationText(event: event, title: title),
        "event": event.rawValue,
        "title": title,
        "sessionId": sessionId,
        "cwd": cwd,
    ]
    // Sorted keys for deterministic output (aids testing + diffing); never throws
    // for a [String: String], but fall back to a minimal body just in case.
    return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
        ?? Data(#"{"text":"\#(notificationText(event: event, title: title))"}"#.utf8)
}
