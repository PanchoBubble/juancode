import Foundation

/// Two agent sessions shown side by side (or stacked) in one pane, made by dragging a
/// sidebar session onto the open one (juancode-8rk). Symmetric: selecting either
/// member shows both, in the same places, with the selected one holding the keyboard.
public struct SessionPair: Equatable, Sendable {
    /// The leading (side by side) or top (stacked) session.
    public var first: String
    /// The trailing or bottom session.
    public var second: String
    public var axis: SessionSplitAxis
    /// `first`'s share of the pane along `axis`, kept inside `SessionPaneLayout.fractionRange`.
    public var fraction: Double

    public init(first: String, second: String, axis: SessionSplitAxis, fraction: Double = 0.5) {
        self.first = first
        self.second = second
        self.axis = axis
        self.fraction = SessionPaneLayout.clamp(fraction)
    }

    public func contains(_ id: String) -> Bool { id == first || id == second }

    /// The other member, or nil when `id` is not in this pair.
    public func partner(of id: String) -> String? {
        id == first ? second : id == second ? first : nil
    }
}

/// Where a session dragged over the pane would land: the half nearest the pointer.
public enum SessionDropZone: Equatable, Sendable {
    case leading, trailing, top, bottom

    /// The zone for a pointer at `point` in a pane of `size`: whichever edge is
    /// nearest, relative to the pane's extent, so a wide pane still offers top/bottom.
    public static func at(_ point: CGPoint, in size: CGSize) -> SessionDropZone {
        let w = max(1, size.width), h = max(1, size.height)
        let x = min(max(0, point.x), w) / w, y = min(max(0, point.y), h) / h
        if min(x, 1 - x) <= min(y, 1 - y) {
            return x < 0.5 ? .leading : .trailing
        }
        return y < 0.5 ? .top : .bottom
    }

    public var axis: SessionSplitAxis {
        self == .leading || self == .trailing ? .sideBySide : .stacked
    }

    /// Whether the dropped session takes the first (leading/top) place.
    public var dropsFirst: Bool { self == .leading || self == .top }

    /// The half of a pane of `size` this zone highlights.
    public func rect(in size: CGSize) -> CGRect {
        let w = max(0, size.width), h = max(0, size.height)
        switch self {
        case .leading: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .trailing: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }
}

/// Every session pair, a session in at most one. Pure bookkeeping, like
/// `SessionEditorTabs`: the panes live in the view, this only records who is
/// beside whom.
public struct SessionPairs: Equatable, Sendable {
    public private(set) var pairs: [SessionPair] = []

    public init() {}

    public func pair(for id: String) -> SessionPair? {
        pairs.first { $0.contains(id) }
    }

    /// Show `dropped` beside `target` in `zone`. Either session leaves any pair it
    /// was in first. Refused (false) for a session dropped on itself.
    @discardableResult
    public mutating func split(_ target: String, with dropped: String, zone: SessionDropZone) -> Bool {
        guard target != dropped else { return false }
        pairs.removeAll { $0.contains(target) || $0.contains(dropped) }
        pairs.append(zone.dropsFirst
                     ? SessionPair(first: dropped, second: target, axis: zone.axis)
                     : SessionPair(first: target, second: dropped, axis: zone.axis))
        return true
    }

    /// End the pair `id` is in (it closed, or went back to one pane). Returns the
    /// pair that ended.
    @discardableResult
    public mutating func remove(session id: String) -> SessionPair? {
        guard let idx = pairs.firstIndex(where: { $0.contains(id) }) else { return nil }
        return pairs.remove(at: idx)
    }

    /// A divider drag settled on `fraction` for the pair `id` is in.
    public mutating func setFraction(_ fraction: Double, for id: String) {
        guard let idx = pairs.firstIndex(where: { $0.contains(id) }) else { return }
        pairs[idx].fraction = SessionPaneLayout.clamp(fraction)
    }

    /// Re-lay `id`'s pair along `axis`, keeping who is first.
    public mutating func setAxis(_ axis: SessionSplitAxis, for id: String) {
        guard let idx = pairs.firstIndex(where: { $0.contains(id) }) else { return }
        pairs[idx].axis = axis
    }

    /// Swap which member is first.
    public mutating func swap(for id: String) {
        guard let idx = pairs.firstIndex(where: { $0.contains(id) }) else { return }
        let p = pairs[idx]
        pairs[idx] = SessionPair(first: p.second, second: p.first, axis: p.axis, fraction: 1 - p.fraction)
    }
}

/// Where a pair's two panes and the divider between them sit in the pane area.
/// Unlike the agent | editor split, both members are agents: side by side both keep
/// the full height (the view translates them above the open shell panel instead of
/// reflowing them), stacked both share the height above it.
public struct SessionPairFrames: Equatable, Sendable {
    public var first: CGRect
    public var second: CGRect
    public var divider: CGRect

    public static func layout(size: CGSize, axis: SessionSplitAxis, fraction: Double,
                              bottomInset: CGFloat) -> SessionPairFrames {
        let w = max(0, size.width), h = max(0, size.height)
        let inset = min(max(0, bottomInset), h)
        let f = CGFloat(SessionPaneLayout.clamp(fraction))
        let gap = SessionSplitFrames.gap
        switch axis {
        case .sideBySide:
            let usable = max(0, w - gap)
            let firstW = (usable * f).rounded()
            return SessionPairFrames(
                first: CGRect(x: 0, y: 0, width: firstW, height: h),
                second: CGRect(x: firstW + gap, y: 0, width: usable - firstW, height: h),
                divider: CGRect(x: firstW, y: 0, width: gap, height: h - inset))
        case .stacked:
            let usable = max(0, h - inset - gap)
            let firstH = (usable * f).rounded()
            return SessionPairFrames(
                first: CGRect(x: 0, y: 0, width: w, height: firstH),
                second: CGRect(x: 0, y: firstH + gap, width: w, height: usable - firstH),
                divider: CGRect(x: 0, y: firstH, width: w, height: gap))
        }
    }

    /// `first`'s share for a divider dragged so `first` is `extent` points along
    /// `axis`, the inverse of `layout`.
    public static func fraction(forFirstExtent extent: Double, axis: SessionSplitAxis,
                                size: CGSize, bottomInset: CGFloat) -> Double {
        let span = axis == .sideBySide ? size.width : size.height - min(max(0, bottomInset), size.height)
        let usable = Double(max(0, span - SessionSplitFrames.gap))
        guard usable > 0 else { return SessionPaneLayout.standard.fraction }
        return SessionPaneLayout.clamp(extent / usable)
    }
}
