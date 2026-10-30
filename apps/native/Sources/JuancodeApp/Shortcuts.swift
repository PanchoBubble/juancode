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
import JuancodeDesktop

/// One rebindable app command. The raw value is the stable persistence key, so
/// don't rename cases without a migration.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newSessionSameProject
    case newSessionSplit
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
    case splitEditor
    case togglePin
    case oracle
    case globalIssues
    case focusSessionSearch
    case refreshTerminal
    case toggleChanges
    case openChangesForCurrentSession
    case toggleFileTree
    case githubView
    case beadsView
    case toggleProjects
    case findInTerminal
    case terminalZoomIn
    case terminalZoomOut
    case terminalZoomReset
    case navigateBack
    case navigateForward
    case diffReview
    case toggleChain
    case nextChainTab
    case previousChainTab
    case focusSessionsPanel
    case focusPrsPanel
    case focusLinearTicketsPanel
    case focusChainsPanel
    case focusOraclesPanel

    var id: String { rawValue }

    /// Matches the existing menu titles in App.swift.
    var title: String {
        switch self {
        case .newSessionSplit: return "New Session in Split"
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
        case .splitEditor: return "Split Editor Beside Agent"
        case .togglePin: return "Pin Session to Top"
        case .oracle: return "Oracle"
        case .globalIssues: return "Oracle Tickets"
        case .focusSessionSearch: return "Find Sessions"
        case .refreshTerminal: return "Refresh Terminal"
        case .toggleChanges: return "Toggle Code Changes"
        case .openChangesForCurrentSession: return "Open Changes for Current Session"
        case .toggleFileTree: return "Toggle File Tree"
        case .githubView: return "GitHub"
        case .beadsView: return "Beads"
        case .toggleProjects: return "Toggle Projects Panel"
        case .findInTerminal: return "Find in Terminal"
        case .terminalZoomIn: return "Increase Terminal Font"
        case .terminalZoomOut: return "Decrease Terminal Font"
        case .terminalZoomReset: return "Reset Terminal Font"
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .diffReview: return "Review Diff"
        case .toggleChain: return "Open / Leave Chain"
        case .nextChainTab: return "Next Chain Tab"
        case .previousChainTab: return "Previous Chain Tab"
        case .focusSessionsPanel: return "Focus Sessions"
        case .focusPrsPanel: return "Focus PRs"
        case .focusLinearTicketsPanel: return "Focus Linear Tickets"
        case .focusChainsPanel: return "Focus Chains"
        case .focusOraclesPanel: return "Focus Oracles"
        }
    }

    /// The factory binding — must mirror the original hardcoded shortcuts.
    var defaultBinding: KeyBinding {
        switch self {
        case .newSessionSplit: return KeyBinding(key: "s", command: true)
        case .newSessionSameProject: return KeyBinding(key: "n", command: true)
        case .newSessionSheet: return KeyBinding(key: "n", command: true, shift: true)
        // ⌘K is the jump palette (juancode-dr0); prompt templates moved to ⌘⇧K.
        case .jumpPalette: return KeyBinding(key: "k", command: true)
        // ⌘P is Quick Open — fuzzy file open in the selected session's worktree.
        case .quickOpen: return KeyBinding(key: "p", command: true)
        case .promptTemplates: return KeyBinding(key: "k", command: true, shift: true)
        case .sessionTemplates: return KeyBinding(key: "l", command: true)
        // ⌥⌘P: ⌘⇧P went to Focus PRs (juancode-2wp).
        case .togglePerfHud: return KeyBinding(key: "p", command: true, option: true)
        case .keepAwake: return KeyBinding(key: "a", shift: true, control: true)
        case .recalcGeometry: return KeyBinding(key: "r", shift: true, control: true)
        case .toggleTerminal: return KeyBinding(key: "t", control: true)
        // ⌘E opens the selected session's worktree in $EDITOR (nvim) in a tab beside it.
        case .openEditor: return KeyBinding(key: "e", command: true)
        // ⌘\ shows the agent and its editor at once (opening the editor if needed),
        // and back to tabs — the split-pane key in most editors.
        case .splitEditor: return KeyBinding(key: "\\", command: true)
        // ⇧⌃P pins/unpins whatever list you're looking at (the Oracle rail when the
        // dock is open, else the sidebar selection). Shift+control so it never eats
        // a TUI's own ⌃P (nvim completion, readline history).
        case .togglePin: return KeyBinding(key: "p", shift: true, control: true)
        case .oracle: return KeyBinding(key: "space", control: true)
        case .globalIssues: return KeyBinding(key: "i", command: true, shift: true)
        case .focusSessionSearch: return KeyBinding(key: "f", control: true)
        case .refreshTerminal: return KeyBinding(key: "z", control: true)
        case .toggleChanges: return KeyBinding(key: "c", command: true)
        // ⌥⌘C jumps straight to the working-tree diff (and clears the review badge),
        // vs ⌘C which just toggles the panel's visibility. It was ⌘⇧C until that
        // went to Focus Chains (juancode-2wp).
        case .openChangesForCurrentSession: return KeyBinding(key: "c", command: true, option: true)
        // ⌘⇧E shows/hides the file-tree sidebar (the Files side-panel tab) — the
        // explorer convention, next to ⌘E which opens the editor session.
        case .toggleFileTree: return KeyBinding(key: "e", command: true, shift: true)
        // ⌘⇧G toggles the GitHub view — all open PRs per project (juancode-2t6).
        case .githubView: return KeyBinding(key: "g", command: true, shift: true)
        case .beadsView: return KeyBinding(key: "b", command: true, shift: true)
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
        // ⌘[ / ⌘] mirror the mouse's side buttons: step back and forward through the
        // sessions you've viewed. Back closes an open overlay first, if any.
        case .navigateBack: return KeyBinding(key: "[", command: true)
        case .navigateForward: return KeyBinding(key: "]", command: true)
        // ⌘⇧D opens the full-width diff review over the session (juancode-a5j).
        case .diffReview: return KeyBinding(key: "d", command: true, shift: true)
        // The chain view: ⌃⌘C opens the selected session's chain and
        // leaves an open one; ⌃⌘] / ⌃⌘[ step through its tabs. Not ⌘⇧] — a shifted
        // bracket arrives as "}" and could never match from inside a terminal.
        case .toggleChain: return KeyBinding(key: "c", command: true, control: true)
        case .nextChainTab: return KeyBinding(key: "]", command: true, control: true)
        case .previousChainTab: return KeyBinding(key: "[", command: true, control: true)
        // ⌘⇧ + a panel's letter reveals that panel and asks it for the keyboard
        // (juancode-2wp). One simultaneous chord, not a modifier-only leader.
        case .focusSessionsPanel: return KeyBinding(key: "s", command: true, shift: true)
        case .focusPrsPanel: return KeyBinding(key: "p", command: true, shift: true)
        case .focusLinearTicketsPanel: return KeyBinding(key: "l", command: true, shift: true)
        case .focusChainsPanel: return KeyBinding(key: "c", command: true, shift: true)
        case .focusOraclesPanel: return KeyBinding(key: "o", command: true, shift: true)
        }
    }

    /// Factory bindings a later layout moved, keyed by the schema version that moved
    /// them. A persisted binding still equal to its old default is migrated to the new
    /// one exactly once, when the stored schema is older; see `Shortcuts.load`.
    static let displacedDefaults: [(schema: Int, action: ShortcutAction, old: KeyBinding)] = [
        (2, .togglePerfHud, KeyBinding(key: "p", command: true, shift: true)),
        (2, .openChangesForCurrentSession, KeyBinding(key: "c", command: true, shift: true)),
    ]

    /// The ⌘⇧ panel shortcuts, in menu order.
    static let panelFocusActions: [ShortcutAction] = [
        .focusSessionsPanel, .focusPrsPanel, .focusLinearTicketsPanel, .focusChainsPanel, .focusOraclesPanel,
    ]

    /// The panel this action focuses, if it is one of the ⌘⇧ panel shortcuts.
    var panelFocusTarget: PanelFocusTarget? {
        switch self {
        case .focusSessionsPanel: .sessions
        case .focusPrsPanel: .prs
        case .focusLinearTicketsPanel: .linearTickets
        case .focusChainsPanel: .chains
        case .focusOraclesPanel: .oracles
        default: nil
        }
    }
}

/// Keys the app handles itself, outside the rebindable table, in the window key
/// monitor (`installPaneNavigation`). Listed so Settings can flag a binding that
/// collides with one — ⌃E wins over any binding; the rest lose to it.
struct FixedShortcut {
    let binding: KeyBinding
    let title: String

    static let all: [FixedShortcut] = [
        FixedShortcut(binding: KeyBinding(key: "e", control: true), title: "Open Editor (built-in)"),
        FixedShortcut(binding: KeyBinding(key: "1", command: true), title: "Agent Tab (built-in)"),
        FixedShortcut(binding: KeyBinding(key: "2", command: true), title: "Editor Tab (built-in)"),
        FixedShortcut(binding: KeyBinding(key: "n", control: true), title: "New Oracle in Dock (built-in)"),
    ]
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
    /// Which factory layout the persisted bindings were last migrated to.
    private let schemaKey = "juancode.shortcuts.schema"
    static let currentSchema = 2
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

    /// Built-in keys this action's binding collides with.
    func fixedConflicts(for action: ShortcutAction) -> [FixedShortcut] {
        let b = binding(for: action)
        guard b.isBound else { return [] }
        return FixedShortcut.all.filter { $0.binding == b }
    }

    /// The action that fires for a chord several actions share: one the user bound
    /// on purpose beats a factory default, so a new default never steals a custom
    /// chord. Both the menu and the window key monitor go through this, so a
    /// shared chord fires exactly one action.
    func owner(of binding: KeyBinding) -> ShortcutAction? {
        guard binding.isBound else { return nil }
        let key = ShortcutTable.owner(
            of: binding, order: ShortcutAction.allCases.map(\.rawValue),
            effective: { self.bindings[$0] ?? ShortcutAction(rawValue: $0)!.defaultBinding },
            isCustom: { !self.isDefault(ShortcutAction(rawValue: $0)!) })
        return key.flatMap(ShortcutAction.init(rawValue:))
    }

    /// True when another action owns this action's chord, so pressing it won't run
    /// this one.
    func isShadowed(_ action: ShortcutAction) -> Bool {
        let b = binding(for: action)
        return b.isBound && owner(of: b) != action
    }

    /// The bound action whose key+modifiers match this key-down event, if any.
    /// Reads live bindings, so it tracks Settings edits without a rebuild.
    func action(matching event: NSEvent) -> ShortcutAction? {
        guard let hit = ShortcutAction.allCases.first(where: { binding(for: $0).matches(event) })
        else { return nil }
        return owner(of: binding(for: hit))
    }

    private func load() {
        let defaults = UserDefaults.standard
        let schema = defaults.integer(forKey: schemaKey)
        defer { if schema < Self.currentSchema { defaults.set(Self.currentSchema, forKey: schemaKey) } }
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return }
        bindings = decoded
        guard schema < Self.currentSchema else { return }
        // A stored binding still equal to a default this layout moved is a leftover
        // ("Reset All" persists every default), not a choice: let it follow the move.
        var displaced: [String: KeyBinding] = [:]
        for entry in ShortcutAction.displacedDefaults where entry.schema > schema {
            displaced[entry.action.rawValue] = entry.old
        }
        let migrated = ShortcutTable.migrateDisplacedDefaults(bindings, displaced: displaced)
        if migrated != bindings {
            bindings = migrated
            save()
        }
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
    /// A chord another action owns is left off this item, so the menu never holds
    /// two items with one key equivalent (AppKit would pick one arbitrarily).
    func appShortcut(_ action: ShortcutAction, _ shortcuts: Shortcuts) -> some View {
        let b = shortcuts.binding(for: action)
        let shortcut = shortcuts.isShadowed(action)
            ? nil : KeyboardShortcut(b.keyEquivalent, modifiers: b.modifiers)
        return keyboardShortcut(shortcut)
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
    case .newSessionSplit: model.quickNewSplitSession()
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
    case .splitEditor:
        if let sel = model.selection { model.toggleSplitEditor(sel) }
    case .togglePin:
        if let id = pinShortcutTarget(model: model, oracle: oracle) { model.togglePinned(id) }
    case .oracle: oracle.toggleChatFocused()
    case .globalIssues: model.openOracleBeads()
    case .focusSessionSearch: model.focusSessionSearch()
    case .refreshTerminal:
        // Refresh whichever terminal you're looking at: the Oracle chat when the
        // dock is open, else the selected session's pane.
        if oracle.expanded { oracle.refreshChat() } else { model.deepRefreshSelectedTerminal() }
    case .toggleChanges: model.toggleChangesPanel()
    case .openChangesForCurrentSession:
        if let id = model.selection { model.openChanges(for: id) }
    case .toggleFileTree: model.toggleFileTreePanel()
    case .githubView: model.toggleGitHubView()
    case .beadsView: model.toggleBeadsView()
    case .toggleProjects: model.toggleProjectsSidebar()
    case .findInTerminal: model.showFindBar()
    case .terminalZoomIn: TerminalZoom.shared.zoomIn()
    case .terminalZoomOut: TerminalZoom.shared.zoomOut()
    case .terminalZoomReset: TerminalZoom.shared.reset()
    case .navigateBack:
        // Browser-shaped: peel off whatever is layered over the session first, and
        // only step back through the session history once the view is bare.
        if !dismissTopOverlay(model: model, oracle: oracle) { model.goBack() }
    case .navigateForward: model.goForward()
    case .diffReview: model.toggleDiffReview()
    case .toggleChain: model.toggleChainForSelection()
    case .nextChainTab: model.stepChainTab(by: 1)
    case .previousChainTab: model.stepChainTab(by: -1)
    case .focusSessionsPanel, .focusPrsPanel, .focusLinearTicketsPanel,
         .focusChainsPanel, .focusOraclesPanel:
        if let target = action.panelFocusTarget { model.requestPanelFocus(target) }
    }
}

/// The session ⇧⌃P acts on: the Oracle showing in the dock when it's open, else the
/// sidebar's selected session. Shared by the shortcut and its menu item so the title
/// always names what the key will actually do.
@MainActor
func pinShortcutTarget(model: AppModel, oracle: OracleModel) -> String? {
    if oracle.expanded, let id = oracle.oracleSessionId { return id }
    return model.selection
}

/// Menu title for the pin command, flipped to "Unpin" once its target is pinned.
@MainActor
func pinCommandTitle(model: AppModel, oracle: OracleModel) -> String {
    let pinned = pinShortcutTarget(model: model, oracle: oracle).map(model.isPinned) ?? false
    return pinned ? "Unpin Session" : "Pin Session to Top"
}

/// Close the topmost thing layered over the visible session, innermost first, and
/// report whether anything was actually closed. Sheets are deliberately absent —
/// they own the keyboard and dismiss themselves on Esc, and the callers are gated
/// on no sheet being attached. The persistent side panels (Changes, Files,
/// Projects) are absent too: those are layout the user set, not a place they
/// navigated to, so a stray back click shouldn't reshuffle the window.
@MainActor
func dismissTopOverlay(model: AppModel, oracle: OracleModel) -> Bool {
    if model.showingFindBar { model.closeFindBar(); return true }
    if model.editing != nil { model.editing = nil; return true }
    if model.showingDiffReview { model.closeDiffReview(); return true }
    // PR lists live in the rail; dismiss the detail overlay directly.
    if model.showingGitHub {
        model.showingGitHub = false
        return true
    }
    if model.showingBeads { model.beadsBack(); return true }
    if oracle.expanded { oracle.collapse(); return true }
    // The chain view is a place you went to, so Back leaves it — after the dock,
    // which an Oracle tab slid in over it.
    if model.chainView != nil { model.exitChain(); return true }
    return false
}
