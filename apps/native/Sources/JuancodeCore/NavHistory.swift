import Foundation

/// Browser-style back/forward history over the ids the user has viewed, driven by
/// the mouse's side buttons (and ⌘[ / ⌘]). Pure so the stack semantics — which
/// mostly show up in the awkward cases: repeats, dead entries, a back followed by
/// a fresh jump — are unit-testable apart from the app model.
///
/// The app layer records every *user-initiated* move by handing over the id being
/// left behind, and asks for a target when the user navigates. Moves that the
/// history itself caused must not be recorded, or back and forward would fight
/// each other; the caller guards that with a flag around the assignment.
public struct NavHistory: Sendable, Equatable {
    /// Ids behind the current one, oldest first.
    public private(set) var back: [String] = []
    /// Ids ahead of the current one, oldest first (so the next forward is `.last`).
    public private(set) var forward: [String] = []
    private let cap: Int

    public init(cap: Int = 50) {
        self.cap = max(1, cap)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Record a user-initiated navigation away from `previous` (the id that was
    /// selected before the move; nil when nothing was). Like a browser, taking a
    /// new branch discards the forward stack. Re-selecting the same id is not a
    /// move, so consecutive duplicates never stack up.
    public mutating func record(leaving previous: String?) {
        guard let previous else { return }
        guard back.last != previous else { return }
        back.append(previous)
        trim(&back)
        forward.removeAll()
    }

    /// The id to go back to from `current`, or nil when there's nowhere to go.
    /// Entries that no longer exist (deleted sessions) are skipped, not surfaced.
    /// `current` moves onto the forward stack so a forward returns to it.
    public mutating func goBack(from current: String?, exists: (String) -> Bool) -> String? {
        var source = back, destination = forward
        defer { back = source; forward = destination }
        return Self.step(popping: &source, pushing: &destination,
                         from: current, exists: exists, cap: cap)
    }

    /// The id to go forward to from `current`, mirroring `goBack`.
    public mutating func goForward(from current: String?, exists: (String) -> Bool) -> String? {
        var source = forward, destination = back
        defer { forward = source; back = destination }
        return Self.step(popping: &source, pushing: &destination,
                         from: current, exists: exists, cap: cap)
    }

    /// Drop ids that are gone for good, so a long session doesn't keep dead
    /// entries the user has to click past twice.
    public mutating func prune(keeping valid: Set<String>) {
        back = dedupeAdjacent(back.filter(valid.contains))
        forward = dedupeAdjacent(forward.filter(valid.contains))
    }

    private static func step(
        popping source: inout [String], pushing destination: inout [String],
        from current: String?, exists: (String) -> Bool, cap: Int
    ) -> String? {
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

    private func trim(_ stack: inout [String]) {
        if stack.count > cap { stack.removeFirst(stack.count - cap) }
    }

    private func dedupeAdjacent(_ ids: [String]) -> [String] {
        ids.reduce(into: [String]()) { acc, id in
            if acc.last != id { acc.append(id) }
        }
    }
}
