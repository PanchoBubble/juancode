import Observation
import JuancodeCore

// The panels ⌘⇧S / P / L / C / O focus (juancode-2wp). `AppModel.requestPanelFocus`
// reveals the panel and publishes a `PanelFocusRequest`; the panel's own view
// consumes the request to take the keyboard and start a browse highlight.

/// A panel a ⌘⇧ shortcut can focus.
enum PanelFocusTarget: String, CaseIterable, Sendable {
    case sessions, prs, linearTickets, chains, oracles
}

/// One focus request. `serial` grows with every request, so pressing the same
/// shortcut twice is still a change a view's `.onChange` sees.
struct PanelFocusRequest: Equatable, Sendable {
    let target: PanelFocusTarget
    let serial: Int
}

struct PanelRowAction: Identifiable {
    let id: String
    let label: String
    let perform: () -> Void
}

struct PanelNavigationRow: Identifiable {
    let id: String
    var actions: [PanelRowAction] = []
    var isInitial: Bool = false
    let open: () -> Void
}

@Observable @MainActor
final class PanelNavigation {
    private(set) var target: PanelFocusTarget?
    private(set) var cursor = PanelBrowseState()
    @ObservationIgnored private var rows: [PanelNavigationRow] = []

    func begin(_ target: PanelFocusTarget, rows: [PanelNavigationRow]) {
        if self.target != target { cursor = PanelBrowseState() }
        self.target = target
        update(rows)
    }

    func update(_ rows: [PanelNavigationRow]) {
        self.rows = rows
        var next = cursor
        next.reconcile(rows.map(\.id), actions: rows.first { $0.id == cursor.rowID }?.actions.map(\.id) ?? [])
        if cursor.rowID == nil, let initial = rows.first(where: \.isInitial) { next.browse(initial.id) }
        if next != cursor { cursor = next }
    }

    func end() { target = nil; rows = []; cursor = PanelBrowseState() }
    func isFocused(_ target: PanelFocusTarget, row: String) -> Bool {
        self.target == target && cursor.rowID == row
    }
    var selectedActionLabel: String? { currentRow?.actions.first { $0.id == cursor.actionID }?.label }
    private var currentRow: PanelNavigationRow? { rows.first { $0.id == cursor.rowID } }

    @discardableResult
    func performAction(_ id: String) -> Bool {
        guard let action = currentRow?.actions.first(where: { $0.id == id }) else { return false }
        action.perform()
        return true
    }

    func handle(_ key: UInt16) -> Bool {
        if target == .sessions {
            let action: String?
            switch key {
            case 45: action = "new" // n
            case 8: action = "close" // c
            case 2: action = "delete" // d
            case 14: action = "rename" // e
            case 35: action = "pin" // p
            default: action = nil
            }
            if let action { _ = performAction(action); return true }
        }
        switch key {
        case 38, 125: cursor.moveRow(1) // j / ↓
        case 40, 126: cursor.moveRow(-1) // k / ↑
        case 4, 123: cursor.moveAction(-1, actions: currentRow?.actions.map(\.id) ?? [])
        case 37, 124: cursor.moveAction(1, actions: currentRow?.actions.map(\.id) ?? [])
        case 36, 76:
            if let action = cursor.actionID { currentRow?.actions.first { $0.id == action }?.perform() }
            else { currentRow?.open() }
        default: return false
        }
        return true
    }
}

