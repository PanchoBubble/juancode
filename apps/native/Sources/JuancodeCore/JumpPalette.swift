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
