import AppKit
import UserNotifications

/// Thin `UNUserNotificationCenter` plumbing for background-session agent
/// notifications (juancode-bao). The should-we-notify decision is the pure
/// `agentNotificationEffect` in JuancodeCore; this only owns delivery: lazy
/// authorization on first post, per-session coalescing (one outstanding
/// notification per session id — reusing the id replaces, never stacks), and
/// routing a click back to the session.
///
/// `@unchecked Sendable`: `UNUserNotificationCenterDelegate` callbacks arrive off
/// the main actor, so the type can't be `@MainActor`. `onSelect` is set once from
/// the main actor before any notification can be delivered; `authRequested` is only
/// touched from `post(...)`, which the `@MainActor` `AppModel` alone calls.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Invoked with the session id when its notification is clicked. Set once at
    /// `start()`; it hops to the main actor itself.
    var onSelect: (@Sendable (String) -> Void)?

    private var authRequested = false

    /// A bare `swift run` executable has no bundle identifier, and
    /// `UNUserNotificationCenter.current()` traps for such a process. Only touch it
    /// inside a real app bundle (the signed .app — juancode-u34.9); in a dev run this
    /// is nil and every entry point below no-ops, leaving the Dock bounce as the only
    /// surfacing.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Register as the delegate so clicks route back through `onSelect`. Per Apple's
    /// docs this must happen before the app finishes launching — `AppModel.init`
    /// (which calls this) runs inside `JuancodeApp.init`, ahead of that.
    func start() {
        center?.delegate = self
    }

    /// Post (or replace) the notification for one session. `critical` picks the
    /// louder waiting-for-input framing.
    func post(sessionId: String, title: String, subtitle: String, body: String, critical: Bool) {
        guard let center else { return }
        requestAuthIfNeeded(center)
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Agent" : title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        content.userInfo = ["sessionId": sessionId]
        // Same identifier per session ⇒ a newer edge replaces the outstanding one
        // instead of piling up a stack of stale dings.
        let request = UNNotificationRequest(
            identifier: "juancode.agent.\(sessionId)", content: content, trigger: nil)
        center.add(request)
    }

    /// Drop any outstanding notification for a session once it has been seen (the
    /// user selected it / returned to the app), so a background ding doesn't linger
    /// in Notification Center after you've already looked.
    func clear(sessionId: String) {
        guard let center else { return }
        let id = "juancode.agent.\(sessionId)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func requestAuthIfNeeded(_ center: UNUserNotificationCenter) {
        guard !authRequested else { return }
        authRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate (called off the main actor)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            onSelect?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // We only post for hidden/inactive sessions, but the app can be frontmost
        // with a *different* pane selected — show the banner there too.
        completionHandler([.banner, .sound])
    }
}
