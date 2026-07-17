import Foundation

/// The app-wide SwiftTerm renderer choice (juancode-epmq): CoreGraphics (the
/// default) or the opt-in Metal path SwiftTerm 1.13 ships. Metal removes the
/// per-frame attributed-string rebuild that makes the CoreText path CPU-bound
/// under heavy agent streaming, but it is still young upstream (rendering
/// artifacts with some CJK content), so it's a user-facing toggle rather than
/// the default.
///
/// One GLOBAL choice drives every SwiftTerm surface — live panes, exited-session
/// replays, and the editor pane all render through `TerminalHostView`, which
/// applies the current choice on window attach and re-applies on `didChange`.
/// Persisted in UserDefaults; first launch can be seeded via
/// `JUANCODE_SWIFTTERM_METAL=1`. Same singleton + notification fan-out pattern
/// as `TerminalZoom`.
@MainActor
final class TerminalRenderer {
    static let shared = TerminalRenderer()

    // Nonisolated so nonisolated view code can register an observer for it
    // without hopping the actor just to read a constant.
    nonisolated static let didChange = Notification.Name("juancode.terminalRenderer.didChange")

    private let defaultsKey = "juancode.terminal.metalRenderer"

    private(set) var metalEnabled: Bool

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            metalEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
        } else {
            metalEnabled = ProcessInfo.processInfo.environment["JUANCODE_SWIFTTERM_METAL"] == "1"
        }
    }

    func setMetalEnabled(_ enabled: Bool) {
        guard enabled != metalEnabled else { return }
        metalEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
