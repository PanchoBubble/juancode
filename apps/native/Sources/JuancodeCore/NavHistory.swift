import Foundation

/// Browser-style back/forward history over the destinations the user has viewed, driven by
/// the mouse's side buttons (and ⌘[ / ⌘]). Pure so the stack semantics — which
/// mostly show up in the awkward cases: repeats, dead entries, a back followed by
/// a fresh jump — are unit-testable apart from the app model.
///
/// The app layer records every *user-initiated* move by handing over the destination being
/// left behind, and asks for a target when the user navigates. Moves that the
/// history itself caused must not be recorded, or back and forward would fight
/// each other; the caller guards that with a flag around the assignment.
public struct NavigationHistory<Destination: Equatable>: Equatable {
    /// Destinations behind the current one, oldest first.
    public private(set) var back: [Destination] = []
    /// Destinations ahead of the current one, oldest first (so the next forward is `.last`).
    public private(set) var forward: [Destination] = []
    private let cap: Int

    public init(cap: Int = 50) {
        self.cap = max(1, cap)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Record a user-initiated navigation away from `previous` (the destination that was
    /// selected before the move; nil when nothing was). Like a browser, taking a
    /// new branch discards the forward stack. Re-selecting the same destination is not a
    /// move, so consecutive duplicates never stack up.
    public mutating func record(leaving previous: Destination?) {
        forward.removeAll()
        guard let previous else { return }
        guard back.last != previous else { return }
        back.append(previous)
        trim(&back)
    }

    /// The destination to go back to from `current`, or nil when there's nowhere to go.
    /// Entries that no longer exist (deleted sessions) are skipped, not surfaced.
    /// `current` moves onto the forward stack so a forward returns to it.
    public mutating func goBack(from current: Destination?, exists: (Destination) -> Bool) -> Destination? {
        var source = back, destination = forward
        defer { back = source; forward = destination }
        return Self.step(popping: &source, pushing: &destination,
                         from: current, exists: exists, cap: cap)
    }

    /// The destination to go forward to from `current`, mirroring `goBack`.
    public mutating func goForward(from current: Destination?, exists: (Destination) -> Bool) -> Destination? {
        var source = forward, destination = back
        defer { forward = source; back = destination }
        return Self.step(popping: &source, pushing: &destination,
                         from: current, exists: exists, cap: cap)
    }

    /// Drop destinations that are gone for good, so a long session doesn't keep dead
    /// entries the user has to click past twice.
    public mutating func prune(keeping isValid: (Destination) -> Bool) {
        back = dedupeAdjacent(back.filter(isValid))
        forward = dedupeAdjacent(forward.filter(isValid))
    }

    private static func step(
        popping source: inout [Destination], pushing destination: inout [Destination],
        from current: Destination?, exists: (Destination) -> Bool, cap: Int
    ) -> Destination? {
        while let candidate = source.popLast() {
            guard candidate != current, exists(candidate) else { continue }
            if let current {
                destination.append(current)
                if destination.count > cap { destination.removeFirst(destination.count - cap) }
            }
            return candidate
        }
        return nil
    }

    private func trim(_ stack: inout [Destination]) {
        if stack.count > cap { stack.removeFirst(stack.count - cap) }
    }

    private func dedupeAdjacent(_ ids: [Destination]) -> [Destination] {
        ids.reduce(into: [Destination]()) { acc, id in
            if acc.last != id { acc.append(id) }
        }
    }
}

extension NavigationHistory: Sendable where Destination: Sendable {}

/// Session-only history retained for callers that navigate by session id.
public typealias NavHistory = NavigationHistory<String>

extension NavigationHistory where Destination == String {
    public mutating func prune(keeping valid: Set<String>) {
        prune(keeping: { valid.contains($0) })
    }
}
