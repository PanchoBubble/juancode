// Editable keyboard shortcuts (juancode-oe4).
//
// App-level commands used to be hardcoded in App.swift via `.keyboardShortcut`.
// This file makes each one user-rebindable: `Shortcuts` is an @Observable store
// of `KeyBinding`s persisted to UserDefaults, and `App.swift` reads the live
// binding for each command so edits in the Settings window take effect. The
// Settings UI lives in ShortcutSettingsView.swift.

import Foundation
import Observation
import SwiftUI
import AppKit

/// One rebindable app command. The raw value is the stable persistence key, so
/// don't rename cases without a migration.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newSessionSameProject
    case newSessionSheet
    case promptTemplates
    case togglePerfHud
    case keepAwake
    case recalcGeometry
    case toggleTerminal
    case oracle
    case globalIssues

    var id: String { rawValue }

    /// Matches the existing menu titles in App.swift.
    var title: String {
        switch self {
        case .newSessionSameProject: return "New Session (same agent & folder)"
        case .newSessionSheet: return "New Session…"
        case .promptTemplates: return "Prompt Templates…"
        case .togglePerfHud: return "Toggle Performance HUD"
        case .keepAwake: return "Keep Awake"
        case .recalcGeometry: return "Recalculate Terminal Geometry"
        case .toggleTerminal: return "Toggle Terminal"
        case .oracle: return "Oracle (chat)"
        case .globalIssues: return "Global Issues"
        }
    }

    /// The factory binding — must mirror the original hardcoded shortcuts.
    var defaultBinding: KeyBinding {
        switch self {
        case .newSessionSameProject: return KeyBinding(key: "n", command: true)
        case .newSessionSheet: return KeyBinding(key: "n", command: true, shift: true)
        case .promptTemplates: return KeyBinding(key: "k", command: true)
        case .togglePerfHud: return KeyBinding(key: "p", command: true, shift: true)
        case .keepAwake: return KeyBinding(key: "a", shift: true, control: true)
        case .recalcGeometry: return KeyBinding(key: "r", shift: true, control: true)
        case .toggleTerminal: return KeyBinding(key: "t", control: true)
        case .oracle: return KeyBinding(key: "space", control: true)
        case .globalIssues: return KeyBinding(key: "i", command: true, shift: true)
        }
    }
}

/// A key + modifier-flag combination. `key` is a single lowercase character or a
/// special token (currently only "space") for non-character keys. Persisted as
/// JSON in UserDefaults.
struct KeyBinding: Codable, Equatable, Sendable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var control: Bool = false
    var option: Bool = false

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        return m
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": return .space
        case "": return KeyEquivalent(" ")
        default: return KeyEquivalent(Character(key))
        }
    }

    /// A bound shortcut needs at least one modifier and a key, else it'd swallow
    /// plain typing. Unbound combos are simply not applied as menu shortcuts.
    var isBound: Bool { !key.isEmpty && (command || shift || control || option) }

    /// Does this binding match an AppKit key-down event? Compares the exact active
    /// modifier set and the resolved character (case-insensitive, so a shifted key
    /// still matches). Used by the window key monitor to fire app shortcuts while a
    /// terminal holds first responder — see `installPaneNavigation`.
    func matches(_ event: NSEvent) -> Bool {
        guard isBound else { return false }
        let active = event.modifierFlags.intersection([.command, .shift, .control, .option])
        var want: NSEvent.ModifierFlags = []
        if command { want.insert(.command) }
        if shift { want.insert(.shift) }
        if control { want.insert(.control) }
        if option { want.insert(.option) }
        guard active == want else { return false }
        switch key {
        case "space": return event.keyCode == 49
        case "": return false
        default: return (event.charactersIgnoringModifiers ?? "").lowercased() == key
        }
    }

    /// Human label like `⌘⇧N` or `⌃Space`.
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "space": s += "Space"
        case "": s += "—"
        default: s += key.uppercased()
        }
        return s
    }
}

/// Observable store of the user's shortcut bindings, persisted to UserDefaults.
/// Unset actions fall back to their `defaultBinding`.
@MainActor
@Observable
final class Shortcuts {
    private let defaultsKey = "juancode.shortcuts.v1"
    private(set) var bindings: [String: KeyBinding] = [:]

    init() { load() }

    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action.rawValue] ?? action.defaultBinding
    }

    func setBinding(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action.rawValue] = binding
        save()
    }

    func reset(_ action: ShortcutAction) {
        bindings[action.rawValue] = action.defaultBinding
        save()
    }

    func resetAll() {
        for action in ShortcutAction.allCases { bindings[action.rawValue] = action.defaultBinding }
        save()
    }

    func isDefault(_ action: ShortcutAction) -> Bool {
        binding(for: action) == action.defaultBinding
    }

    /// Other actions sharing this action's exact key+modifiers (a real conflict
    /// only matters for bound combos).
    func conflicts(for action: ShortcutAction) -> [ShortcutAction] {
        let b = binding(for: action)
        guard b.isBound else { return [] }
        return ShortcutAction.allCases.filter { $0 != action && binding(for: $0) == b }
    }

    /// The bound action whose key+modifiers match this key-down event, if any.
    /// Reads live bindings, so it tracks Settings edits without a rebuild.
    func action(matching event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { binding(for: $0).matches(event) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return }
        bindings = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension View {
    /// Apply a (possibly rebound) shortcut to a command button. Reading the live
    /// binding here keeps the menu key-equivalent in sync with the Settings edit.
    func appShortcut(_ action: ShortcutAction, _ shortcuts: Shortcuts) -> some View {
        let b = shortcuts.binding(for: action)
        return keyboardShortcut(b.keyEquivalent, modifiers: b.modifiers)
    }
}

/// Run a shortcut's effect. The single source of truth for what each command does,
/// shared by the menu commands (App.swift) and the window key monitor
/// (`installPaneNavigation`) so the two never drift. The monitor needs this because
/// a focused terminal swallows ⌘-key events before the main menu's key equivalents
/// ever fire — so it intercepts the event and dispatches the action here directly.
@MainActor
func performShortcut(_ action: ShortcutAction, model: AppModel, oracle: OracleModel) {
    switch action {
    case .newSessionSameProject: model.quickNewSession()
    case .newSessionSheet: model.showingNewSession = true
    case .promptTemplates: model.showingPromptPalette = true
    case .togglePerfHud: PerfMonitor.shared.visible.toggle()
    case .keepAwake: model.keepAwake.toggle()
    case .recalcGeometry: model.resyncTerminalGeometry()
    case .toggleTerminal: model.toggleBottomTerminal()
    case .oracle: oracle.toggleChatFocused()
    case .globalIssues: oracle.open(tab: .issues)
    }
}
