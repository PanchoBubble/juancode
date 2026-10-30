// The panels ⌘⇧S / P / L / C / O focus (juancode-2wp). `AppModel.requestPanelFocus`
// reveals the panel and publishes a `PanelFocusRequest`; the panel's own view
// consumes the request to take the keyboard and start a browse highlight.

/// A panel a ⌘⇧ shortcut can focus.
enum PanelFocusTarget: String, CaseIterable, Sendable {
    case sessions, prs, linearTickets, chains, oracles

    /// The right-rail panel that shows this target; nil for the sessions sidebar.
    var railPanel: RightRailPanel? {
        switch self {
        case .sessions: nil
        case .prs: .prs
        case .linearTickets: .tickets
        case .chains: .chains
        case .oracles: .oracle
        }
    }
}

/// One focus request. `serial` grows with every request, so pressing the same
/// shortcut twice is still a change a view's `.onChange` sees.
struct PanelFocusRequest: Equatable, Sendable {
    let target: PanelFocusTarget
    let serial: Int
}
