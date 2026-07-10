import Foundation

/// Pure fuzzy matching + ranking for the Quick Open file palette — a subsequence
/// scorer that returns both a rank and the matched-character ranges (so the UI can
/// highlight the hit), plus a tiny per-worktree file-list cache the palette invalidates
/// off the FSEvents watcher. Kept pure so scoring, ranking, match ranges, and cache
/// invalidation are unit-testable apart from the SwiftUI layer and the `git ls-files`
/// shell-out. Distinct from `JumpPalette`'s `fuzzyScore`, which ranks sessions and
/// carries no match ranges; this one is path-aware (weights the filename over its
/// directory) and highlight-aware.

/// One fuzzy hit: a rank plus the character-offset ranges in the candidate the query
/// matched, merged into contiguous runs and ascending — for highlighting.
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    public let ranges: [Range<Int>]

    public init(score: Int, ranges: [Range<Int>]) {
        self.score = score
        self.ranges = ranges
    }
}

/// Case-insensitive subsequence match of `query` in a file `path`, scored, with the
/// matched offsets. nil when the query is not a subsequence. Greedy left-to-right —
/// cheap and predictable, not an optimal alignment. Scoring favours what an editor's
/// Quick Open wants: matches in the filename over its directory, prefix and
/// word-boundary hits (`/ - _ . space`), and consecutive runs.
public func fuzzyMatchPath(query: String, in path: String) -> FuzzyMatch? {
    let q = Array(query.lowercased())
    if q.isEmpty { return FuzzyMatch(score: 0, ranges: []) }
    let t = Array(path)
    let boundaries: Set<Character> = ["/", "-", "_", ".", " "]
    // First index of the basename (past the last "/"); matches here weigh more.
    let basenameStart = (t.lastIndex(of: "/").map { $0 + 1 }) ?? 0

    var score = 0
    var ti = 0
    var prevMatch = -2  // not adjacent to index 0
    var matched: [Int] = []
    matched.reserveCapacity(q.count)
    for ch in q {
        var found = false
        while ti < t.count {
            if Character(t[ti].lowercased()) == ch {
                score += 1
                if ti == prevMatch + 1 { score += 5 }
                if ti == 0 { score += 8 } else if boundaries.contains(t[ti - 1]) { score += 6 }
                if ti >= basenameStart { score += 3 }
                matched.append(ti)
                prevMatch = ti
                ti += 1
                found = true
                break
            }
            ti += 1
        }
        if !found { return nil }
    }
    // Prefer tight matches in short paths over the same hits lost in a long one.
    score -= min(t.count - q.count, 10)
    return FuzzyMatch(score: score, ranges: mergeAdjacent(matched))
}

/// Collapse an ascending list of matched offsets into contiguous `[start, end)` runs.
private func mergeAdjacent(_ indices: [Int]) -> [Range<Int>] {
    guard var start = indices.first else { return [] }
    var prev = start
    var out: [Range<Int>] = []
    for i in indices.dropFirst() {
        if i == prev + 1 { prev = i; continue }
        out.append(start ..< (prev + 1))
        start = i
        prev = i
    }
    out.append(start ..< (prev + 1))
    return out
}

/// One ranked Quick Open candidate: its worktree-relative path, its match score, and
/// the offsets to highlight.
public struct QuickOpenItem: Sendable, Equatable, Identifiable {
    public let path: String
    public let score: Int
    public let ranges: [Range<Int>]
    public var id: String { path }

    public init(path: String, score: Int, ranges: [Range<Int>]) {
        self.path = path
        self.score = score
        self.ranges = ranges
    }
}

/// Filter + rank `paths` against `query`, capped at `limit`. An empty query keeps the
/// input order (git already sorts `ls-files`) and just takes the first `limit`. With a
/// query, non-matching paths drop out and the rest sort by score, then by shorter path,
/// then lexicographically — a stable, deterministic order. The score is computed per
/// path in one greedy pass, so a 10k-path list ranks in a few milliseconds per keystroke.
public func quickOpenResults(_ paths: [String], query: String, limit: Int = 200) -> [QuickOpenItem] {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty {
        return paths.prefix(limit).map { QuickOpenItem(path: $0, score: 0, ranges: []) }
    }
    var scored: [QuickOpenItem] = []
    scored.reserveCapacity(min(paths.count, limit * 4))
    for p in paths {
        if let m = fuzzyMatchPath(query: q, in: p) {
            scored.append(QuickOpenItem(path: p, score: m.score, ranges: m.ranges))
        }
    }
    scored.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }
    if scored.count > limit { scored = Array(scored.prefix(limit)) }
    return scored
}

/// A tiny per-worktree cache of file lists for Quick Open. The palette reads the
/// cached list on open (instant), the FSEvents watcher invalidates the entry when the
/// tree changes, and a miss triggers a fresh `git ls-files`. Pure value type so the
/// store/invalidate/miss transitions are unit-testable without the app or a real tree.
public struct FileIndex: Sendable, Equatable {
    private var byPath: [String: [String]] = [:]

    public init() {}

    /// The cached file list for a worktree, or nil when absent or invalidated.
    public func files(for path: String) -> [String]? { byPath[path] }

    /// True when `path` has a live (non-invalidated) cached list.
    public func isCached(_ path: String) -> Bool { byPath[path] != nil }

    /// Cache (or refresh) a worktree's file list.
    public mutating func store(_ files: [String], for path: String) { byPath[path] = files }

    /// Drop a worktree's cached list so the next read re-indexes. Idempotent.
    public mutating func invalidate(_ path: String) { byPath[path] = nil }
}
