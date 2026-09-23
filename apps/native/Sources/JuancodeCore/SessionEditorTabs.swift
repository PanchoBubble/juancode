import Foundation

/// Which of a session's in-place tabs is in front: its agent, or the editor opened
/// beside it (the `</>` header button, ⌘E).
public enum SessionPaneTab: Equatable, Sendable {
    case agent, editor
}

/// The in-place editor tabs, one editor at most per session. Pure bookkeeping: the
/// ptys live on the model, keyed by `editorId`; this only records which session owns
/// which editor and which tab is in front, so the rules (reopen focuses, an exit
/// drops back to the agent, a replaced editor's late exit is ignored) are testable.
public struct SessionEditorTabs: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let sessionId: String
        public let editorId: String
        public var id: String { editorId }
    }

    /// Session id → editor pty id.
    private var editors: [String: String] = [:]
    /// Sessions whose editor tab is in front.
    private var editorInFront: Set<String> = []

    public init() {}

    public func editorId(for sessionId: String) -> String? { editors[sessionId] }

    public func hasEditor(_ sessionId: String) -> Bool { editors[sessionId] != nil }

    public func activeTab(for sessionId: String) -> SessionPaneTab {
        editorInFront.contains(sessionId) && editors[sessionId] != nil ? .editor : .agent
    }

    /// Every open editor, in a stable order, so a view can keep all of them mounted
    /// across session switches.
    public var entries: [Entry] {
        editors.map { Entry(sessionId: $0.key, editorId: $0.value) }
            .sorted { $0.editorId < $1.editorId }
    }

    /// Record a freshly spawned editor for `sessionId` and bring it to the front.
    /// Returns the editor it replaced, which the caller should kill.
    @discardableResult
    public mutating func opened(_ editorId: String, for sessionId: String) -> String? {
        let replaced = editors[sessionId].flatMap { $0 == editorId ? nil : $0 }
        editors[sessionId] = editorId
        editorInFront.insert(sessionId)
        return replaced
    }

    /// Bring `tab` to the front. Selecting the editor of a session that has none is
    /// refused (returns false) so the strip never points at a missing pane.
    @discardableResult
    public mutating func select(_ tab: SessionPaneTab, for sessionId: String) -> Bool {
        switch tab {
        case .agent:
            editorInFront.remove(sessionId)
            return true
        case .editor:
            guard editors[sessionId] != nil else { return false }
            editorInFront.insert(sessionId)
            return true
        }
    }

    /// Flip between the two tabs; a no-op without an editor. Returns the tab now in front.
    @discardableResult
    public mutating func toggle(for sessionId: String) -> SessionPaneTab {
        let next: SessionPaneTab = activeTab(for: sessionId) == .editor ? .agent : .editor
        select(next, for: sessionId)
        return activeTab(for: sessionId)
    }

    /// The editor `editorId` exited. Returns the session it belonged to, or nil when
    /// it is not the current editor of any session (already replaced or closed).
    @discardableResult
    public mutating func exited(_ editorId: String) -> String? {
        guard let sessionId = editors.first(where: { $0.value == editorId })?.key else { return nil }
        editors[sessionId] = nil
        editorInFront.remove(sessionId)
        return sessionId
    }

    /// Forget `sessionId`'s editor (its session is going away). Returns the editor id
    /// to kill, if there was one.
    @discardableResult
    public mutating func remove(session sessionId: String) -> String? {
        editorInFront.remove(sessionId)
        return editors.removeValue(forKey: sessionId)
    }
}
