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
    case jumpPalette
    case quickOpen
    case promptTemplates
    case sessionTemplates
    case togglePerfHud
    case keepAwake
    case recalcGeometry
    case toggleTerminal
    case openEditor
    case oracle
    case globalIssues
    case focusSessionSearch
    case refreshTerminal
    case toggleChanges
    case openChangesForCurrentSession
    case toggleFileTree
    case toggleProjects
    case findInTerminal
    case terminalZoomIn
    case terminalZoomOut
    case terminalZoomReset

    var id: String { rawValue }

    /// Matches the existing menu titles in App.swift.
    var title: String {
        switch self {
        case .newSessionSameProject: return "New Session (same agent & folder)"
        case .newSessionSheet: return "New Session…"
        case .jumpPalette: return "Jump to Session…"
        case .quickOpen: return "Quick Open File…"
        case .promptTemplates: return "Prompt Templates…"
        case .sessionTemplates: return "Session Templates…"
        case .togglePerfHud: return "Toggle Performance HUD"
        case .keepAwake: return "Keep Awake"
        case .recalcGeometry: return "Recalculate Terminal Geometry"
        case .toggleTerminal: return "Toggle Terminal"
        case .openEditor: return "Open Editor for Session"
        case .oracle: return "Oracle (chat)"
        case .globalIssues: return "Global Issues"
        case .focusSessionSearch: return "Find Sessions"
        case .refreshTerminal: return "Refresh Terminal"
        case .toggleChanges: return "Toggle Code Changes"
        case .openChangesForCurrentSession: return "Open Changes for Current Session"
        case .toggleFileTree: return "Toggle File Tree"
        case .toggleProjects: return "Toggle Projects Panel"
        case .findInTerminal: return "Find in Terminal"
        case .terminalZoomIn: return "Increase Terminal Font"
        case .terminalZoomOut: return "Decrease Terminal Font"
        case .terminalZoomReset: return "Reset Terminal Font"
        }
    }

    /// The factory binding — must mirror the original hardcoded shortcuts.
    var defaultBinding: KeyBinding {
        switch self {
        case .newSessionSameProject: return KeyBinding(key: "n", command: true)
        case .newSessionSheet: return KeyBinding(key: "n", command: true, shift: true)
        // ⌘K is the jump palette (juancode-dr0); prompt templates moved to ⌘⇧K.
        case .jumpPalette: return KeyBinding(key: "k", command: true)
        // ⌘P is Quick Open — fuzzy file open in the selected session's worktree.
        case .quickOpen: return KeyBinding(key: "p", command: true)
        case .promptTemplates: return KeyBinding(key: "k", command: true, shift: true)
        case .sessionTemplates: return KeyBinding(key: "l", command: true)
        case .togglePerfHud: return KeyBinding(key: "p", command: true, shift: true)
        case .keepAwake: return KeyBinding(key: "a", shift: true, control: true)
        case .recalcGeometry: return KeyBinding(key: "r", shift: true, control: true)
        case .toggleTerminal: return KeyBinding(key: "t", control: true)
        // ⌘E opens the selected session's worktree in $EDITOR (nvim) as a session.
        case .openEditor: return KeyBinding(key: "e", command: true)
        case .oracle: return KeyBinding(key: "space", control: true)
        case .globalIssues: return KeyBinding(key: "i", command: true, shift: true)
        case .focusSessionSearch: return KeyBinding(key: "f", control: true)
        case .refreshTerminal: return KeyBinding(key: "z", control: true)
        case .toggleChanges: return KeyBinding(key: "c", command: true)
        // ⌘⇧C jumps straight to the working-tree diff (and clears the review badge),
        // vs ⌘C which just toggles the panel's visibility.
        case .openChangesForCurrentSession: return KeyBinding(key: "c", command: true, shift: true)
        // ⌘⇧E shows/hides the file-tree sidebar (the Files side-panel tab) — the
        // explorer convention, next to ⌘E which opens the editor session.
        case .toggleFileTree: return KeyBinding(key: "e", command: true, shift: true)
        case .toggleProjects: return KeyBinding(key: "s", control: true)
        // ⌘F opens the in-pane find bar over the visible terminal (juancode-972);
        // ⌃F (focusSessionSearch) stays the sidebar session filter.
        case .findInTerminal: return KeyBinding(key: "f", command: true)
        // Terminal font zoom (juancode-fry). ⌘= is the rebindable primary (the
        // key you can press without shift); ⌘+ (⌘⇧=) is handled as a fixed alias
        // in the window key monitor, the macOS convention for "zoom in".
        case .terminalZoomIn: return KeyBinding(key: "=", command: true)
        case .terminalZoomOut: return KeyBinding(key: "-", command: true)
        case .terminalZoomReset: return KeyBinding(key: "0", command: true)
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
    case .newSessionSameProject:
        // With the Oracle dock open, "new" means a new Oracle session — the dock is
        // the surface you're looking at (⌘N and ⌃N both land here via the monitor).
        if oracle.expanded { oracle.newOracle() } else { model.quickNewSession() }
    case .newSessionSheet: model.showingNewSession = true
    case .jumpPalette: model.showingJumpPalette = true
    case .quickOpen: model.openQuickOpen()
    case .promptTemplates: model.showingPromptPalette = true
    case .sessionTemplates: model.showingSessionTemplates = true
    case .togglePerfHud: PerfMonitor.shared.visible.toggle()
    case .keepAwake: model.keepAwake.toggle()
    case .recalcGeometry: model.resyncTerminalGeometry()
    case .toggleTerminal: model.toggleBottomTerminal()
    case .openEditor: model.openEditorForSelection()
    case .oracle: oracle.toggleChatFocused()
    case .globalIssues: oracle.open(tab: .issues)
    case .focusSessionSearch: model.focusSessionSearch()
    case .refreshTerminal:
        // Refresh whichever terminal you're looking at: the Oracle chat when the
        // dock is open, else the selected session's pane.
        if oracle.expanded { oracle.refreshChat() } else { model.refreshTerminal() }
    case .toggleChanges: model.toggleChangesPanel()
    case .openChangesForCurrentSession:
        if let id = model.selection { model.openChanges(for: id) }
    case .toggleFileTree: model.toggleFileTreePanel()
    case .toggleProjects: model.toggleProjectsSidebar()
    case .findInTerminal: model.showFindBar()
    case .terminalZoomIn: TerminalZoom.shared.zoomIn()
    case .terminalZoomOut: TerminalZoom.shared.zoomOut()
    case .terminalZoomReset: TerminalZoom.shared.reset()
    }
}
