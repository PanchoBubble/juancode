import Foundation
import CoreGraphics

/// An in-place session tab. In a split, the selected tab holds keyboard focus.
public enum SessionPaneTab: Equatable, Sendable {
    case agent, editor
    case terminal(String)
}

/// How a split lays the agent and its editor out: side by side (agent left) or
/// stacked (agent on top).
public enum SessionSplitAxis: String, Codable, Equatable, Sendable {
    case sideBySide, stacked

    public var flipped: SessionSplitAxis { self == .sideBySide ? .stacked : .sideBySide }
}

/// Session tabs and two-pane splits: one agent, at most one editor, and any number
/// of shells. Pty ownership stays on AppModel; this pure state tracks selection,
/// visible panes, and exit handling. The editor API retains its historical name.
public struct SessionEditorTabs: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let sessionId: String
        public let editorId: String
        public var id: String { editorId }
    }

    /// Session id → editor pty id.
    private var editors: [String: String] = [:]
    private var terminals: [String: [String]] = [:]
    private var selected: [String: SessionPaneTab] = [:]
    private var companions: [String: SessionPaneTab] = [:]
    private var primary: [String: SessionPaneTab] = [:]
    private var splits: [String: SessionSplitAxis] = [:]

    public init() {}

    public func editorId(for sessionId: String) -> String? { editors[sessionId] }

    public func hasEditor(_ sessionId: String) -> Bool { editors[sessionId] != nil }

    public func terminalIds(for sessionId: String) -> [String] { terminals[sessionId] ?? [] }

    public func tabs(for sessionId: String) -> [SessionPaneTab] {
        [.agent] + (hasEditor(sessionId) ? [.editor] : []) + terminalIds(for: sessionId).map { .terminal($0) }
    }

    public func activeTab(for sessionId: String) -> SessionPaneTab { selected[sessionId] ?? .agent }
    public func primaryTab(for sessionId: String) -> SessionPaneTab { primary[sessionId] ?? .agent }
    public func companionTab(for sessionId: String) -> SessionPaneTab { companions[sessionId] ?? .editor }
    public func splitAxis(for sessionId: String) -> SessionSplitAxis? { splits[sessionId] }

    public func isShown(_ tab: SessionPaneTab, for sessionId: String) -> Bool {
        guard tabs(for: sessionId).contains(tab) else { return false }
        if splits[sessionId] != nil {
            return tab == primaryTab(for: sessionId) || tab == companionTab(for: sessionId)
        }
        return activeTab(for: sessionId) == tab
    }

    public mutating func openedTerminal(_ id: String, for sessionId: String) {
        terminals[sessionId, default: []].append(id)
        select(.terminal(id), for: sessionId)
    }

    /// Put a tab beside the currently focused tab, including two shell terminals.
    @discardableResult
    public mutating func splitWith(_ tab: SessionPaneTab, axis: SessionSplitAxis, for sessionId: String) -> Bool {
        guard tabs(for: sessionId).contains(tab), tab != activeTab(for: sessionId) else { return false }
        primary[sessionId] = activeTab(for: sessionId)
        companions[sessionId] = tab
        selected[sessionId] = tab
        splits[sessionId] = axis
        return true
    }

    @discardableResult
    public mutating func closedTerminal(_ id: String, for sessionId: String) -> Bool {
        guard terminalIds(for: sessionId).contains(id) else { return false }
        terminals[sessionId]?.removeAll { $0 == id }
        removedTab(.terminal(id), for: sessionId)
        return true
    }

    public mutating func removeTerminals(for sessionId: String) -> [String] {
        let ids = terminalIds(for: sessionId)
        for id in ids { closedTerminal(id, for: sessionId) }
        terminals[sessionId] = nil
        return ids
    }

    private mutating func removedTab(_ tab: SessionPaneTab, for sessionId: String) {
        if splits[sessionId] != nil && (primaryTab(for: sessionId) == tab || companionTab(for: sessionId) == tab) {
            selected[sessionId] = primaryTab(for: sessionId) == tab ? companionTab(for: sessionId) : primaryTab(for: sessionId)
            splits[sessionId] = nil
        } else if activeTab(for: sessionId) == tab {
            selected[sessionId] = .agent
        }
        if companions[sessionId] == tab { companions[sessionId] = nil }
        if primary[sessionId] == tab { primary[sessionId] = nil }
    }

    /// Every open editor, in a stable order, so a view can keep all of them mounted
    /// across session switches.
    public var entries: [Entry] {
        editors.map { Entry(sessionId: $0.key, editorId: $0.value) }
            .sorted { $0.editorId < $1.editorId }
    }

    /// Record a freshly spawned editor for `sessionId` and bring it to the front,
    /// split along `split` when given. Returns the editor it replaced, which the
    /// caller should kill.
    @discardableResult
    public mutating func opened(_ editorId: String, for sessionId: String,
                                split: SessionSplitAxis? = nil) -> String? {
        let replaced = editors[sessionId].flatMap { $0 == editorId ? nil : $0 }
        editors[sessionId] = editorId
        selected[sessionId] = .editor
        companions[sessionId] = .editor
        primary[sessionId] = .agent
        splits[sessionId] = split
        return replaced
    }

    /// Split the selected companion beside the agent, or change an existing split's axis.
    /// Refused when only the agent exists.
    @discardableResult
    public mutating func split(_ axis: SessionSplitAxis, for sessionId: String) -> Bool {
        guard tabs(for: sessionId).count > 1 else { return false }
        if splits[sessionId] == nil {
            primary[sessionId] = .agent
            companions[sessionId] = activeTab(for: sessionId) == .agent
                ? tabs(for: sessionId)[1] : activeTab(for: sessionId)
        }
        splits[sessionId] = axis
        return true
    }

    /// Back to one tab at a time, with `keeping` in front: the pane you closed is
    /// the other one.
    public mutating func unsplit(for sessionId: String, keeping: SessionPaneTab) {
        splits[sessionId] = nil
        select(keeping, for: sessionId)
    }

    /// Focus an existing tab, replacing the companion pane if it was not visible.
    @discardableResult
    public mutating func select(_ tab: SessionPaneTab, for sessionId: String) -> Bool {
        guard tabs(for: sessionId).contains(tab) else { return false }
        if splits[sessionId] != nil && tab != primaryTab(for: sessionId) {
            companions[sessionId] = tab
        }
        selected[sessionId] = tab
        return true
    }

    @discardableResult
    public mutating func toggle(for sessionId: String) -> SessionPaneTab {
        let available = tabs(for: sessionId)
        let index = available.firstIndex(of: activeTab(for: sessionId)) ?? 0
        select(available[(index + 1) % available.count], for: sessionId)
        return activeTab(for: sessionId)
    }

    /// The editor `editorId` exited. Returns the session it belonged to, or nil when
    /// it is not the current editor of any session (already replaced or closed).
    @discardableResult
    public mutating func exited(_ editorId: String) -> String? {
        guard let sessionId = editors.first(where: { $0.value == editorId })?.key else { return nil }
        editors[sessionId] = nil
        removedTab(.editor, for: sessionId)
        return sessionId
    }

    /// Forget `sessionId`'s editor (its session is going away). Returns the editor id
    /// to kill, if there was one.
    @discardableResult
    public mutating func remove(session sessionId: String) -> String? {
        selected[sessionId] = nil
        companions[sessionId] = nil
        primary[sessionId] = nil
        splits[sessionId] = nil
        return editors.removeValue(forKey: sessionId)
    }
}

/// A project's remembered split: whether its sessions open their editor beside the
/// agent, along which axis, and how much of the pane the agent gets.
public struct SessionPaneLayout: Codable, Equatable, Sendable {
    public var split: Bool
    public var axis: SessionSplitAxis
    /// The agent's share of the pane along `axis`, kept inside `fractionRange`.
    public var fraction: Double

    /// Neither pane may be dragged narrower than this share: a few-column TUI is
    /// unreadable and its reflow is the garble this split exists to avoid.
    public static let fractionRange: ClosedRange<Double> = 0.2...0.8
    public static let standard = SessionPaneLayout(split: false, axis: .sideBySide, fraction: 0.5)

    public init(split: Bool, axis: SessionSplitAxis, fraction: Double) {
        self.split = split
        self.axis = axis
        self.fraction = Self.clamp(fraction)
    }

    public static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return standard.fraction }
        return min(fractionRange.upperBound, max(fractionRange.lowerBound, fraction))
    }
}

/// `SessionPaneLayout` per project (keyed by the project's cwd), persisted as JSON.
public struct ProjectPaneLayouts: Codable, Equatable, Sendable {
    private var byProject: [String: SessionPaneLayout] = [:]

    public init() {}

    public func layout(for project: String) -> SessionPaneLayout {
        byProject[project] ?? .standard
    }

    public mutating func update(_ project: String, _ change: (inout SessionPaneLayout) -> Void) {
        var layout = layout(for: project)
        change(&layout)
        layout.fraction = SessionPaneLayout.clamp(layout.fraction)
        byProject[project] = layout == .standard ? nil : layout
    }

    public static func decode(_ data: Data?) -> ProjectPaneLayouts {
        data.flatMap { try? JSONDecoder().decode(ProjectPaneLayouts.self, from: $0) } ?? ProjectPaneLayouts()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Where the agent, the editor and the divider between them sit inside a session's
/// pane area. Pure geometry so the reflow rules are testable.
public struct SessionSplitFrames: Equatable, Sendable {
    public var agent: CGRect
    public var editor: CGRect
    /// The gap the divider sits in; zero-sized when not split.
    public var divider: CGRect

    /// Width (side by side) or height (stacked) of the gap between the panes.
    public static let gap: CGFloat = 8

    /// Lay out a pane area of `size`. `bottomInset` is the open shell panel's
    /// height. Unsplit, and side by side, the agent keeps the full height (the view
    /// translates it above the panel instead of reflowing it) while the editor is
    /// inset; stacked, both share the height above the panel, since translating the
    /// top pane would push it out of sight.
    public static func layout(size: CGSize, axis: SessionSplitAxis?, fraction: Double,
                              bottomInset: CGFloat) -> SessionSplitFrames {
        let w = max(0, size.width), h = max(0, size.height)
        let inset = min(max(0, bottomInset), h)
        let f = CGFloat(SessionPaneLayout.clamp(fraction))
        switch axis {
        case nil:
            return SessionSplitFrames(agent: CGRect(x: 0, y: 0, width: w, height: h),
                                      editor: CGRect(x: 0, y: 0, width: w, height: h - inset),
                                      divider: .zero)
        case .sideBySide:
            // The editor on the left, as in an IDE: code first, the agent beside it.
            let usable = max(0, w - gap)
            let agentW = (usable * f).rounded()
            let editorW = usable - agentW
            return SessionSplitFrames(
                agent: CGRect(x: editorW + gap, y: 0, width: agentW, height: h),
                editor: CGRect(x: 0, y: 0, width: editorW, height: h - inset),
                divider: CGRect(x: editorW, y: 0, width: gap, height: h - inset))
        case .stacked:
            let avail = h - inset
            let usable = max(0, avail - gap)
            let agentH = (usable * f).rounded()
            return SessionSplitFrames(
                agent: CGRect(x: 0, y: 0, width: w, height: agentH),
                editor: CGRect(x: 0, y: agentH + gap, width: w, height: usable - agentH),
                divider: CGRect(x: 0, y: agentH, width: w, height: gap))
        }
    }

    /// The agent's share for a divider dragged so the agent is `extent` points
    /// along `axis`, the inverse of `layout`.
    public static func fraction(forAgentExtent extent: Double, axis: SessionSplitAxis,
                                size: CGSize, bottomInset: CGFloat) -> Double {
        let span = axis == .sideBySide ? size.width : size.height - min(max(0, bottomInset), size.height)
        let usable = Double(max(0, span - gap))
        guard usable > 0 else { return SessionPaneLayout.standard.fraction }
        return SessionPaneLayout.clamp(extent / usable)
    }
}
