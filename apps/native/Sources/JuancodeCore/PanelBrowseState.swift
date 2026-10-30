/// Browsing never opens a row. Only the owner interprets an explicit activation.
public struct PanelBrowseState: Equatable {
    public private(set) var rows: [String] = []
    public private(set) var rowID: String?
    public private(set) var actionID: String?
    public init() {}

    public mutating func reconcile(_ ids: [String], actions: [String]) {
        let oldIndex = rowID.flatMap { rows.firstIndex(of: $0) } ?? 0
        rows = ids
        if rowID == nil || !ids.contains(rowID!) {
            rowID = ids.isEmpty ? nil : ids[min(oldIndex, ids.count - 1)]
            actionID = nil
        }
        if let actionID, !actions.contains(actionID) { self.actionID = nil }
    }

    public mutating func browse(_ id: String) {
        guard rows.contains(id) else { return }
        if rowID != id { rowID = id; actionID = nil }
    }

    public mutating func moveRow(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = rowID.flatMap { rows.firstIndex(of: $0) } ?? 0
        let next = rows[max(0, min(rows.count - 1, index + delta))]
        if next != rowID { rowID = next; actionID = nil }
    }

    /// The row itself is the first stop; left from the first action returns to it.
    public mutating func moveAction(_ delta: Int, actions: [String]) {
        let index = actionID.flatMap { actions.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let next = max(0, min(actions.count, index + delta))
        actionID = next == 0 ? nil : actions[next - 1]
    }
}
