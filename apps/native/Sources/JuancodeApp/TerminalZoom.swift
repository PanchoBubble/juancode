import Foundation
import JuancodeCore

/// The app-wide terminal font-zoom level (juancode-fry). One GLOBAL level drives
/// every live terminal surface — the main session panes, the Oracle dock, and the
/// bottom shell panel — so ⌘+/⌘−/⌘0 zoom the whole app in lockstep rather than one
/// pane at a time (juancode has a single primary pane, so per-pane zoom buys nothing
/// over global and costs more state).
///
/// The level persists across launches in UserDefaults. On change we post
/// `didChange`; each terminal coordinator subscribes and re-syncs its surface to the
/// new level (Ghostty via live binding actions, SwiftTerm via its font). Coordinators
/// also read `level` on surface attach so a freshly-spawned pane opens already zoomed.
/// A `NotificationCenter` fan-out (rather than threading a token through SwiftUI)
/// keeps the wiring uniform across all three surface types and both backends.
@MainActor
final class TerminalZoom {
    static let shared = TerminalZoom()

    // Nonisolated so nonisolated coordinators (the SwiftTerm ones) can register an
    // observer for it without hopping the actor just to read a constant.
    nonisolated static let didChange = Notification.Name("juancode.terminalZoom.didChange")

    private let defaultsKey = "juancode.terminalZoom.level"

    private(set) var level: Int

    private init() {
        level = TerminalFontZoom.clamp(UserDefaults.standard.integer(forKey: defaultsKey))
    }

    func zoomIn() { set(TerminalFontZoom.zoomedIn(level)) }
    func zoomOut() { set(TerminalFontZoom.zoomedOut(level)) }
    func reset() { set(0) }

    private func set(_ newLevel: Int) {
        let clamped = TerminalFontZoom.clamp(newLevel)
        guard clamped != level else { return }
        level = clamped
        UserDefaults.standard.set(clamped, forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
