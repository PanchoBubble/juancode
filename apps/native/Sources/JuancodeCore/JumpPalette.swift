import Foundation

/// Attention-first smart sort + fuzzy matching for the ⌘K session jump palette
/// and the sidebar's within-project ordering (juancode-dr0). Pure so the ranking
/// rules are unit-testable apart from the UI model; the app layer builds the
/// inputs from live session state (see `SidebarView.sortKey` / `JumpPaletteView`).

/// How urgently a session wants the user's eyes, most urgent first. Mirrors the
/// sidebar's agent-state vocabulary (juancode-t9p): waiting for a reply beats a
/// finished-but-unseen turn beats an agent still working; quiet live sessions
/// follow, and exited ones sink to the bottom.
public enum SessionAttention: Int, Sendable, Equatable, Comparable {
    case waitingInput = 0
    case doneUnseen = 1
    case working = 2
    case idle = 3
    case exited = 4

    public static func < (a: SessionAttention, b: SessionAttention) -> Bool {
        a.rawValue < b.rawValue
    }
}

/// Bucket one session's live state. The mapping matches `SessionRow.stateGlyph`
/// exactly — same inputs, same precedence — so what sorts first is what glows in
/// the row (waiting amber, done-unseen green, working orange, idle/exited grey).
public func sessionAttention(
    live: Bool, activity: SessionActivity?, unseenDone: Bool
) -> SessionAttention {
    guard live else { return .exited }
    switch activity {
    case .busy: return .working
    case .waitingInput: return .waitingInput
    default: return unseenDone ? .doneUnseen : .idle
    }
}

/// Everything the smart sort needs to know about one session. Timestamps are ms
/// since epoch (the `SessionMeta` shape).
public struct SessionSortKey: Sendable, Equatable {
    public var attention: SessionAttention
    public var updatedAt: Int
    public var createdAt: Int

    public init(attention: SessionAttention, updatedAt: Int, createdAt: Int) {
        self.attention = attention
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

/// Strict-weak ordering for the smart sort: attention bucket first, then most
/// recently active, then most recently created (a stable tie-break for identical
/// `updatedAt`, which bulk-spawned sessions share).
public func smartSortPrecedes(_ a: SessionSortKey, _ b: SessionSortKey) -> Bool {
    if a.attention != b.attention { return a.attention < b.attention }
    if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
    return a.createdAt > b.createdAt
}

/// Attention states that pull a session above the user's manual order — the two
/// that want the user to act: a reply is due, or a finished turn is unseen.
/// Working/idle/exited sessions rest in their manual slot instead.
public func attentionBubblesAboveManualOrder(_ attention: SessionAttention) -> Bool {
    attention == .waitingInput || attention == .doneUnseen
}

/// One session's inputs for the sidebar's stable "sink dead ones" order. `down`
/// is true when the session is no longer live (exited, crashed, or reaped-while-
/// idle/dormant); `createdAt` is ms-since-epoch and `id` is the stable tie-break.
public struct SinkSortKey: Sendable, Equatable {
    public var down: Bool
    public var createdAt: Int
    public var id: String

    public init(down: Bool, createdAt: Int, id: String) {
        self.down = down
        self.createdAt = createdAt
        self.id = id
    }
}

/// Strict-weak ordering that keeps live sessions from churning as they work
/// (juancode-05u): live sessions hold a fixed newest-first (`createdAt` desc)
/// place, and only "down" (exited/dormant) sessions sink to the bottom. Unlike
/// `smartSortPrecedes`, it reads no activity/attention/`updatedAt`, so a session
/// flipping busy↔idle↔waiting never moves — it just re-glyphs in place. `id`
/// breaks ties so bulk-spawned sessions (shared `createdAt`) stay deterministic.
public func sinkDownPrecedes(_ a: SinkSortKey, _ b: SinkSortKey) -> Bool {
    if a.down != b.down { return !a.down }
    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
    return a.id < b.id
}

/// One session's inputs for the sidebar's "manual order + attention bubbling"
/// sort: its smart-sort key plus its slot in the user's persisted drag order
/// (`nil` when the user hasn't placed it yet).
public struct ManualSortKey: Sendable, Equatable {
    public var key: SessionSortKey
    public var manualIndex: Int?

    public init(key: SessionSortKey, manualIndex: Int?) {
        self.key = key
        self.manualIndex = manualIndex
    }
}

/// Strict-weak ordering blending a user's manual drag order with attention
/// bubbling (juancode-dy7): sessions wanting action float to the top (smart-sorted
/// among themselves), and the rest sit in `manualIndex` order — placed sessions
/// before unplaced, unplaced falling back to the smart sort. So a waiting session
/// bubbles up, then drops back to its manual slot once the user has handled it.
public func manualWithBubblePrecedes(_ a: ManualSortKey, _ b: ManualSortKey) -> Bool {
    let aBubble = attentionBubblesAboveManualOrder(a.key.attention)
    let bBubble = attentionBubblesAboveManualOrder(b.key.attention)
    if aBubble != bBubble { return aBubble }
    if aBubble { return smartSortPrecedes(a.key, b.key) }
    switch (a.manualIndex, b.manualIndex) {
    case let (x?, y?): return x < y
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return smartSortPrecedes(a.key, b.key)
    }
}

/// Case-insensitive subsequence match of `query` in `text`, scored; nil when the
/// query is not a subsequence. Greedy left-to-right — cheap and predictable, not
/// an optimal alignment. Scoring favours what a jump palette wants: prefix
/// matches, word-boundary hits (`/ - _ . space`), and consecutive runs.
public func fuzzyScore(query: String, in text: String) -> Int? {
    let q = Array(query.lowercased())
    if q.isEmpty { return 0 }
    let t = Array(text.lowercased())
    let boundaries: Set<Character> = ["/", "-", "_", ".", " "]

    var score = 0
    var ti = 0
    var prevMatch = -2  // not adjacent to index 0
    for ch in q {
        var found = false
        while ti < t.count {
            if t[ti] == ch {
                score += 1
                if ti == prevMatch + 1 { score += 5 }
                if ti == 0 { score += 8 } else if boundaries.contains(t[ti - 1]) { score += 6 }
                prevMatch = ti
                ti += 1
                found = true
                break
            }
            ti += 1
        }
        if !found { return nil }
    }
    // Prefer tight matches in short strings over the same hits lost in a long one.
    score -= min(t.count - q.count, 10)
    return score
}

/// One row the palette can jump to. `title` and `subtitle` are what the query is
/// matched against (title at double weight); `key` drives the attention-first
/// ordering. The UI keeps its own id → session lookup for rendering.
public struct JumpCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var key: SessionSortKey

    public init(id: String, title: String, subtitle: String, key: SessionSortKey) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.key = key
    }
}

/// Filter + order the palette's rows. Empty query → pure smart sort. With a
/// query, non-matching candidates drop out and the survivors keep attention as
/// the primary order (a waiting session should top the list even against a
/// slightly better textual match), with match quality then recency breaking ties.
public func jumpResults(_ candidates: [JumpCandidate], query: String) -> [JumpCandidate] {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return candidates.sorted { smartSortPrecedes($0.key, $1.key) } }
    let scored: [(JumpCandidate, Int)] = candidates.compactMap { c in
        let title = fuzzyScore(query: q, in: c.title).map { $0 * 2 }
        let subtitle = fuzzyScore(query: q, in: c.subtitle)
        guard title != nil || subtitle != nil else { return nil }
        return (c, max(title ?? Int.min, subtitle ?? Int.min))
    }
    return scored.sorted { a, b in
        if a.0.key.attention != b.0.key.attention { return a.0.key.attention < b.0.key.attention }
        if a.1 != b.1 { return a.1 > b.1 }
        return smartSortPrecedes(a.0.key, b.0.key)
    }
    .map(\.0)
}
