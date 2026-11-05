import AppKit
import OSLog
import UserNotifications

/// Owns permission, per-session coalescing, and click-through for native alerts.
/// All delivery state is confined to the main actor; delegate callbacks hop here.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onSelect: (@MainActor @Sendable (String) -> Void)?

    private let authorize: @MainActor () async throws -> Bool
    private let submit: @MainActor (UNNotificationRequest) -> Void
    private let remove: @MainActor (String) -> Void
    private var authorizationTask: Task<Bool, Error>?
    private var pending: [String: UUID] = [:]
    nonisolated private static let logger = Logger(subsystem: "dev.juancode.app", category: "notifications")

    /// A bare `swift run` executable cannot use UserNotifications: current() traps
    /// without a bundle identifier. Keep the Dock bounce available in that case.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override convenience init() {
        self.init(authorize: {
            guard Bundle.main.bundleIdentifier != nil else { return false }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                return try await center.requestAuthorization(options: [.alert, .sound])
            case .authorized, .provisional: return true
            default: return false
            }
        }, submit: { request in
            guard Bundle.main.bundleIdentifier != nil else { return }
            UNUserNotificationCenter.current().add(request) { error in
                if let error { AgentNotifier.logger.error("Notification delivery failed: \(error.localizedDescription)") }
            }
        }, remove: { id in
            guard Bundle.main.bundleIdentifier != nil else { return }
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
        })
    }

    /// Injectable delivery boundary for authorization and stale-alert regressions.
    init(authorize: @escaping @MainActor () async throws -> Bool,
         submit: @escaping @MainActor (UNNotificationRequest) -> Void,
         remove: @escaping @MainActor (String) -> Void) {
        self.authorize = authorize
        self.submit = submit
        self.remove = remove
        super.init()
    }

    func start() { center?.delegate = self }

    private func authorizationGranted() async throws -> Bool {
        if let authorizationTask { return try await authorizationTask.value }
        let task = Task { try await authorize() }
        authorizationTask = task
        defer { authorizationTask = nil }
        return try await task.value
    }

    /// Let the user grant permission before the first background question. If they
    /// previously declined, take them to macOS notification settings to enable it.
    func enableNotifications() {
        Task {
            do {
                if try await !authorizationGranted(),
                   let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                Self.logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func post(sessionId: String, title: String, subtitle: String, body: String,
              critical: Bool) -> Task<Void, Never> {
        let token = UUID()
        pending[sessionId] = token
        return Task {
            defer { if pending[sessionId] == token { pending.removeValue(forKey: sessionId) } }
            do {
                // Wait for the permission dialog; never lose the first question by
                // submitting it while authorization is still undetermined.
                guard try await authorizationGranted(), pending[sessionId] == token else { return }
                let content = UNMutableNotificationContent()
                content.title = title.isEmpty ? "Agent" : title
                if !subtitle.isEmpty { content.subtitle = subtitle }
                content.body = body
                // Critical sounds need an Apple-issued entitlement. A normal sound
                // works with ordinary user permission; questions get time sensitivity.
                content.sound = .default
                content.interruptionLevel = critical ? .timeSensitive : .active
                content.userInfo = ["sessionId": sessionId]
                submit(UNNotificationRequest(identifier: identifier(sessionId), content: content, trigger: nil))
            } catch {
                Self.logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    func clear(sessionId: String) {
        // Also invalidate an alert still waiting for the permission dialog, so
        // answering/visiting a session cannot produce a stale banner afterward.
        pending.removeValue(forKey: sessionId)
        remove(identifier(sessionId))
    }

    private func identifier(_ sessionId: String) -> String { "juancode.agent.\(sessionId)" }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            Task { @MainActor in onSelect?(id) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
