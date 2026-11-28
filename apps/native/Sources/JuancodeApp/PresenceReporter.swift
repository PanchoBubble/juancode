import AppKit
import JuancodeServer

/// Tells the sidecar whether the Mac is away (screen locked or display asleep), the
/// gate for phone alerts (juancode-3aq8.7). Event-driven: system notifications only,
/// one POST per change.
@MainActor
final class PresenceReporter {
    private var locked = false
    private var displayAsleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        watch(distributed, "com.apple.screenIsLocked") { $0.locked = true }
        watch(distributed, "com.apple.screenIsUnlocked") { $0.locked = false }
        watch(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displayAsleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displayAsleep = false }
        report()
    }

    private func watch(_ center: NotificationCenter, _ name: String, _ change: @escaping @MainActor (PresenceReporter) -> Void) {
        let token = center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.report()
            }
        }
        observers.append((center, token))
    }

    private func report() {
        PhoneAlerts.post("/api/phone-alerts/presence", ["away": locked || displayAsleep])
    }
}
