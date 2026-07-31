import Foundation

/// The app-wide SwiftTerm renderer choice (juancode-epmq): the Metal path
/// SwiftTerm ships (the default) or CoreGraphics. Metal removes the per-frame
/// attributed-string rebuild that makes the CoreText path CPU-bound under heavy
/// agent streaming. It was opt-in while upstream's glyph placement drifted;
/// SwiftTerm 1.14 fixed that (13732b7, "Align the text") and `Package.swift`
/// floors at 1.15, so it leads now — CoreGraphics stays one toggle away for
/// anyone who hits an artifact.
///
/// Only the SwiftTerm surface reads this: the Ghostty surface (the default one,
/// see `TerminalBackend`) is GPU-rendered either way.
///
/// One GLOBAL choice drives every SwiftTerm surface — live panes, exited-session
/// replays, and the editor pane all render through `TerminalHostView`, which
/// applies the current choice on window attach and re-applies on `didChange`.
/// Persisted in UserDefaults; a first launch can opt out with
/// `JUANCODE_SWIFTTERM_METAL=0`. Same singleton + notification fan-out pattern
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
            metalEnabled = ProcessInfo.processInfo.environment["JUANCODE_SWIFTTERM_METAL"] != "0"
        }
    }

    func setMetalEnabled(_ enabled: Bool) {
        guard enabled != metalEnabled else { return }
        metalEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
