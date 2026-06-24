import Foundation

/// Stable identifier for one terminal pane (one shell pty). A tab owns one or two
/// of these; splitting a tab adds a second pane id.
public typealias TerminalPaneID = UUID

/// One VS Code-style terminal tab. Owns one pane, or two side-by-side panes once
/// split. The pane ids are stable so the SwiftUI layer (and the pty map living in
/// `AppModel`) can key live ptys off them across re-renders.
public struct TerminalTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    /// One pane normally; two after a split. Never empty.
    public var panes: [TerminalPaneID]

    public init(id: UUID = UUID(), title: String, panes: [TerminalPaneID]) {
        self.id = id
        self.title = title
        self.panes = panes
    }

    public var isSplit: Bool { panes.count > 1 }
}

/// Pure, testable model of the bottom terminal panel for ONE workdir: an ordered
/// list of tabs plus which tab is active. Holds no ptys — `AppModel` maps each
/// `TerminalPaneID` to a live `EphemeralPty`. All mutating ops return the pane ids
/// that became orphaned (so the caller can kill their ptys) and keep the
/// active-tab selection sensible.
public struct TerminalPanelModel: Equatable, Sendable {
    public private(set) var tabs: [TerminalTab]
    public private(set) var activeTabID: UUID?

    public init(tabs: [TerminalTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public var isEmpty: Bool { tabs.isEmpty }

    public var activeTab: TerminalTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Sequential default title ("Terminal 1", "Terminal 2", …) that never collides
    /// with an existing tab title.
    private func nextTitle() -> String {
        var n = tabs.count + 1
        let existing = Set(tabs.map(\.title))
        while existing.contains("Terminal \(n)") { n += 1 }
        return "Terminal \(n)"
    }

    /// Append a fresh single-pane tab and make it active. Returns the new pane id
    /// (the caller spawns a pty for it).
    @discardableResult
    public mutating func addTab() -> TerminalPaneID {
        let pane = TerminalPaneID()
        let tab = TerminalTab(title: nextTitle(), panes: [pane])
        tabs.append(tab)
        activeTabID = tab.id
        return pane
    }

    /// Close the tab with `id`, choosing a neighbouring tab as the new active one.
    /// Returns the pane ids that the closed tab owned, so the caller can kill them.
    @discardableResult
    public mutating func closeTab(_ id: UUID) -> [TerminalPaneID] {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let orphaned = tabs[idx].panes
        tabs.remove(at: idx)
        if activeTabID == id {
            if tabs.isEmpty {
                activeTabID = nil
            } else {
                activeTabID = tabs[Swift.min(idx, tabs.count - 1)].id
            }
        }
        return orphaned
    }

    /// Make `id` the active tab (no-op if it doesn't exist).
    public mutating func selectTab(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) { activeTabID = id }
    }

    /// Split the active tab into two side-by-side panes. Returns the new pane id, or
    /// nil if there's no active tab or it's already split (max two panes).
    @discardableResult
    public mutating func splitActiveTab() -> TerminalPaneID? {
        guard let id = activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }),
              !tabs[idx].isSplit else { return nil }
        let pane = TerminalPaneID()
        tabs[idx].panes.append(pane)
        return pane
    }

    /// Collapse the active tab's split, removing the SECOND pane. Returns the removed
    /// pane id (to kill its pty), or nil if there's nothing to collapse.
    @discardableResult
    public mutating func unsplitActiveTab() -> TerminalPaneID? {
        guard let id = activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }),
              tabs[idx].isSplit else { return nil }
        return tabs[idx].panes.removeLast()
    }

    /// Every pane id across all tabs (used to kill all ptys on teardown).
    public func allPanes() -> [TerminalPaneID] { tabs.flatMap(\.panes) }
}
