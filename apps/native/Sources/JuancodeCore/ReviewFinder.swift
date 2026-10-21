import Foundation

/// Pure matching behind the diff-review panel's finders: the file picker (⌃P / ␣ff),
/// live grep over every changed line of the review (␣fg / ␣/), and vim's in-file
/// `/` `?` `n` `N`. Search semantics are the `diff-review` plugin's
/// (`~/.claude/mods/diff-review/hooks/view.tsx` `smartcase` / `searchStep`): a literal
/// pattern, case-insensitive unless it holds an uppercase letter, wrapping at the ends.

// MARK: - Smartcase

/// True when `pattern` should match case-sensitively: it has an uppercase letter.
public func reviewIsCaseSensitive(_ pattern: String) -> Bool {
    pattern != pattern.lowercased()
}

/// Every non-overlapping occurrence of `pattern` in `text`, as character-offset ranges,
/// ascending. Literal (no regex), smartcase. Empty pattern: none.
public func reviewSmartcaseRanges(_ pattern: String, in text: String) -> [Range<Int>] {
    guard !pattern.isEmpty else { return [] }
    let options: String.CompareOptions = reviewIsCaseSensitive(pattern) ? [.literal] : [.caseInsensitive, .literal]
    var out: [Range<Int>] = []
    var from = text.startIndex
    while from < text.endIndex, let hit = text.range(of: pattern, options: options, range: from..<text.endIndex) {
        let lo = text.distance(from: text.startIndex, to: hit.lowerBound)
        out.append(lo..<(lo + text.distance(from: hit.lowerBound, to: hit.upperBound)))
        // A zero-width hit cannot happen for a non-empty literal, but never spin.
        from = hit.upperBound > hit.lowerBound ? hit.upperBound : text.index(after: hit.lowerBound)
    }
    return out
}

/// True when the row is a code line containing `pattern` — hunk headers and notes are
/// never search hits, as in the plugin.
public func reviewRowMatches(_ row: ReviewRow, pattern: String) -> Bool {
    guard !pattern.isEmpty, let line = row.line else { return false }
    let options: String.CompareOptions = reviewIsCaseSensitive(pattern) ? [.literal] : [.caseInsensitive, .literal]
    return line.text.range(of: pattern, options: options) != nil
}

// MARK: - In-file search

/// Where a search step lands, and whether it wrapped past an end to get there.
public struct ReviewSearchHit: Sendable, Equatable {
    public let row: Int
    public let wrapped: Bool

    public init(row: Int, wrapped: Bool) {
        self.row = row
        self.wrapped = wrapped
    }
}

/// The next row matching `pattern` after (or before) row `from`, wrapping around the
/// file and finally trying `from` itself — the plugin's `jumpTo(…, wraps: true)`.
/// `from` may be -1 (before the first row). nil when nothing in the file matches.
public func reviewSearch(_ rows: [ReviewRow], pattern: String, from: Int, forward: Bool) -> ReviewSearchHit? {
    guard !pattern.isEmpty, !rows.isEmpty else { return nil }
    let here = min(max(from, -1), rows.count)
    let after = Array(max(0, here + 1)..<rows.count)
    let before = Array(0..<max(0, min(here, rows.count)))
    let wrap = rows.indices.contains(here) ? [here] : []
    let order: [(Int, Bool)] = forward
        ? after.map { ($0, false) } + before.map { ($0, true) } + wrap.map { ($0, true) }
        : before.reversed().map { ($0, false) } + after.reversed().map { ($0, true) } + wrap.map { ($0, true) }
    guard let hit = order.first(where: { reviewRowMatches(rows[$0.0], pattern: pattern) }) else { return nil }
    return ReviewSearchHit(row: hit.0, wrapped: hit.1)
}

// MARK: - File finder

/// One file-finder result: the file and the path offsets its query matched.
public struct ReviewFileHit: Sendable, Equatable, Identifiable {
    public let file: DiffFile
    public let ranges: [Range<Int>]
    public var id: String { file.path }

    public init(file: DiffFile, ranges: [Range<Int>]) {
        self.file = file
        self.ranges = ranges
    }
}

/// The review's files matching `query`, best first — Quick Open's path-aware fuzzy
/// scorer (`fuzzyMatchPath`), made smartcase. An empty query lists every file in tree
/// order, the order gt/gT step through.
public func reviewFileFinder(_ files: [DiffFile], query: String) -> [ReviewFileHit] {
    let q = query.trimmingCharacters(in: .whitespaces)
    let order = reviewFileOrder(files)
    let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    let ordered = order.compactMap { byPath[$0] }
    if q.isEmpty { return ordered.map { ReviewFileHit(file: $0, ranges: []) } }
    let sensitive = reviewIsCaseSensitive(q)
    var scored: [(hit: ReviewFileHit, score: Int, at: Int)] = []
    for (at, f) in ordered.enumerated() {
        guard let m = fuzzyMatchPath(query: q, in: f.path, caseSensitive: sensitive) else { continue }
        scored.append((ReviewFileHit(file: f, ranges: m.ranges), m.score, at))
    }
    scored.sort { a, b in a.score != b.score ? a.score > b.score : a.at < b.at }
    return scored.map(\.hit)
}

// MARK: - Live grep

/// One changed file's rows, as the panel renders them — what grep searches and what a
/// hit's `row` indexes into.
public struct ReviewGrepFile: Sendable, Equatable {
    public let path: String
    public let rows: [ReviewRow]

    public init(path: String, rows: [ReviewRow]) {
        self.path = path
        self.rows = rows
    }
}

/// Every changed file's rows, in tree order. Built once per opened finder.
public func reviewGrepIndex(_ files: [DiffFile]) -> [ReviewGrepFile] {
    let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    return reviewFileOrder(files).compactMap { path in
        byPath[path].map { ReviewGrepFile(path: path, rows: reviewRows(for: $0)) }
    }
}

/// One grep result: a code line of a changed file, with the matched offsets in its text.
public struct ReviewGrepHit: Sendable, Equatable, Identifiable {
    public let path: String
    /// The row's index in `reviewRows(for:)` of that file — where Enter puts the cursor.
    public let row: Int
    public let line: DiffLine
    public let ranges: [Range<Int>]
    public var id: String { "\(path)\u{0}\(row)" }

    public init(path: String, row: Int, line: DiffLine, ranges: [Range<Int>]) {
        self.path = path
        self.row = row
        self.line = line
        self.ranges = ranges
    }

    /// `path:12`, or `path:5 (old)` for a removed line.
    public var location: String { "\(path):\(reviewLineLabel(line))" }
}

/// The code lines of every file containing `query`, literal and smartcase, in tree
/// order then line order, capped at `limit`. An empty query finds nothing.
public func reviewGrep(_ index: [ReviewGrepFile], query: String, limit: Int = 500) -> [ReviewGrepHit] {
    guard !query.isEmpty else { return [] }
    var out: [ReviewGrepHit] = []
    for file in index {
        for (i, row) in file.rows.enumerated() {
            guard let line = row.line else { continue }
            let ranges = reviewSmartcaseRanges(query, in: line.text)
            guard !ranges.isEmpty else { continue }
            out.append(ReviewGrepHit(path: file.path, row: i, line: line, ranges: ranges))
            if out.count >= limit { return out }
        }
    }
    return out
}
