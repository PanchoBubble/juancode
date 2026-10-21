import Foundation

/// Pure model behind the full-width diff-review panel (juancode-a5j): the rows one
/// file's diff renders as, line comments anchored to them, the review message those
/// comments are sent as, the flattened file tree, and the vim key parser. A port of
/// the `diff-review` Claude Code plugin (`~/.claude/mods/diff-review/hooks/{git,
/// review,tree,view}.ts`) — the send format in particular is byte-for-byte that
/// plugin's `formatReview`, so a review reads the same whichever surface wrote it.
///
/// No SwiftUI and no git: the diff arrives as `DiffFile`s from the core.

// MARK: - Bases

/// What the review diffs against.
public enum ReviewBase: String, CaseIterable, Sendable, Codable {
    /// The working tree vs HEAD, untracked files included.
    case head
    /// The working tree vs the merge base with the main branch.
    case main
    /// The index vs HEAD.
    case staged

    /// Short name for the base picker.
    public var title: String {
        switch self {
        case .head: return "Working tree"
        case .main: return "Branch vs main"
        case .staged: return "Staged"
        }
    }

    /// The label the review message names its diff by. `ref` is the branch a `.main`
    /// diff resolved its merge base against; nil means none was found.
    public func label(ref: String? = nil) -> String {
        switch self {
        case .head: return "working tree vs HEAD"
        case .staged: return "staged vs HEAD"
        case .main:
            guard let ref, !ref.isEmpty else { return "working tree vs HEAD (no main branch found)" }
            return "working tree vs merge-base(\(ref))"
        }
    }

    /// The next base in picker order, for cycling.
    public var next: ReviewBase {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - Rows

/// One row of a file's review diff.
public enum ReviewRow: Sendable, Equatable {
    /// An `@@ -a,b +c,d @@` hunk header.
    case hunk(String)
    /// A context, added or removed line.
    case line(DiffLine)
    /// Something that is not a line: "binary file", a truncation marker.
    case note(String)

    public var line: DiffLine? {
        if case .line(let l) = self { return l }
        return nil
    }
}

/// Lines past this many are cut with a note, like the plugin's `MAX_LINES_PER_FILE`.
public let reviewMaxLinesPerFile = 4000

/// The rows a file's diff renders as. Tabs become four spaces (what the plugin shows
/// and quotes); a binary or oversized file is a single note.
public func reviewRows(for file: DiffFile, maxLines: Int = reviewMaxLinesPerFile) -> [ReviewRow] {
    if file.binary { return [.note("binary file")] }
    if file.truncated { return [.note("diff too large to display")] }
    var rows: [ReviewRow] = []
    for hunk in parseUnifiedDiff(file.diff) {
        if rows.count >= maxLines { break }
        rows.append(.hunk(hunk.header))
        for line in hunk.lines {
            if rows.count >= maxLines { break }
            rows.append(.line(DiffLine(kind: line.kind, oldLine: line.oldLine, newLine: line.newLine,
                                       text: line.text.replacingOccurrences(of: "\t", with: "    "))))
        }
    }
    if rows.count >= maxLines { rows.append(.note("… diff truncated")) }
    return rows
}

/// What a comment is keyed by, so it finds its line again after a refresh: the new-side
/// line number, or the old-side one for a removed line. `n12`, `o5`.
public func reviewLineKey(_ line: DiffLine) -> String {
    if let n = line.newLine { return "n\(n)" }
    return "o\(line.oldLine ?? 0)"
}

/// The line number a comment names: `12`, or `5 (old)` for a removed line.
public func reviewLineLabel(_ line: DiffLine) -> String {
    if let n = line.newLine { return "\(n)" }
    return "\(line.oldLine ?? 0) (old)"
}

/// The index of the row carrying `key` in `rows`, if that line is still in the diff.
public func reviewRowIndex(forKey key: String, in rows: [ReviewRow]) -> Int? {
    rows.firstIndex { $0.line.map(reviewLineKey) == key }
}

// MARK: - Comments

/// A comment on one line or a range of lines of one file.
public struct ReviewComment: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var path: String
    public var startLabel: String
    public var endLabel: String
    /// `reviewLineKey` of the last commented line — where the comment renders and what
    /// it survives a refresh by.
    public var endKey: String
    /// The commented lines, each with its `+`/`-`/space marker.
    public var excerpt: [String]
    public var text: String

    public init(id: String, path: String, startLabel: String, endLabel: String, endKey: String,
                excerpt: [String], text: String) {
        self.id = id; self.path = path; self.startLabel = startLabel; self.endLabel = endLabel
        self.endKey = endKey; self.excerpt = excerpt; self.text = text
    }

    /// `path:12` or `path:10-14`.
    public var location: String {
        let range = startLabel == endLabel ? startLabel : "\(startLabel)-\(endLabel)"
        return "\(path):\(range)"
    }
}

/// A comment over rows `from...to` (either order) of `path`. Hunk headers and notes in
/// the range are skipped; nil when the range holds no code line.
public func makeReviewComment(path: String, rows: [ReviewRow], from: Int, to: Int, text: String,
                              id: String = UUID().uuidString) -> ReviewComment? {
    let lo = max(0, min(from, to))
    let hi = min(rows.count - 1, max(from, to))
    guard lo <= hi else { return nil }
    let picked = rows[lo...hi].compactMap(\.line)
    guard let first = picked.first, let last = picked.last else { return nil }
    return ReviewComment(
        id: id, path: path,
        startLabel: reviewLineLabel(first), endLabel: reviewLineLabel(last),
        endKey: reviewLineKey(last),
        excerpt: picked.map { reviewMarker($0.kind) + $0.text },
        text: text)
}

private func reviewMarker(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .insert: return "+"
    case .delete: return "-"
    case .context: return " "
    }
}

/// The message a review is sent as — the plugin's `formatReview`, exactly:
///
///     Review comments on my diff (<base label>). Address each one:
///
///     1. `path:start-end`
///     ```diff
///     <excerpt>
///     ```
///     <comment>
public func formatReview(_ comments: [ReviewComment], baseLabel: String) -> String {
    let parts = comments.enumerated().map { i, c in
        (["\(i + 1). `\(c.location)`", "```diff"] + c.excerpt + ["```", c.text])
            .joined(separator: "\n")
    }
    return [
        "Review comments on my diff (\(baseLabel)). Address each one:",
        "",
        parts.joined(separator: "\n\n"),
    ].joined(separator: "\n")
}

// MARK: - File tree

/// One visible row of the review's file tree.
public struct ReviewTreeRow: Sendable, Equatable, Identifiable {
    /// The node id: the full path of a file, or of a (possibly compressed) folder.
    public let id: String
    /// What the row shows: a file name, or `a/b/c` for a compressed folder chain.
    public let name: String
    public let depth: Int
    /// The file this row opens; nil for a folder.
    public let file: DiffFile?
    public let isCollapsed: Bool
    /// The file's counts, or the folder's totals.
    public let additions: Int
    public let deletions: Int

    public var isDirectory: Bool { file == nil }
}

/// The tree's rows top to bottom, folders first, skipping what is under a collapsed
/// folder. Built on `buildFileTree`, which already compresses single-child folders.
public func reviewTreeRows(_ files: [DiffFile], collapsed: Set<String>) -> [ReviewTreeRow] {
    var rows: [ReviewTreeRow] = []
    func walk(_ nodes: [FileTreeNode], depth: Int) {
        for node in nodes {
            let isCollapsed = node.isDirectory && collapsed.contains(node.id)
            rows.append(ReviewTreeRow(id: node.id, name: node.name, depth: depth, file: node.file,
                                      isCollapsed: isCollapsed,
                                      additions: node.additions, deletions: node.deletions))
            if let kids = node.children, !isCollapsed { walk(kids, depth: depth + 1) }
        }
    }
    walk(buildFileTree(files), depth: 0)
    return rows
}

/// File paths in tree order — the order gt/gT step through.
public func reviewFileOrder(_ files: [DiffFile]) -> [String] {
    reviewTreeRows(files, collapsed: []).compactMap { $0.file?.path }
}

// MARK: - Keys

/// What a key sequence asks the review panel to do. Where it applies (the diff or the
/// tree) is the panel's call; the parser only reads keys.
public enum ReviewKeyCommand: Sendable, Equatable {
    case down(Int), up(Int)
    case left, right
    /// `gg`, or `<n>gg` / `<n>G` to a line number.
    case top, bottom, goToLine(Int)
    case halfPageDown, halfPageUp
    case nextHunk(Int), prevHunk(Int)
    case nextFile(Int), prevFile(Int)
    case nextComment, prevComment
    case toggleVisual
    /// `gcc` in normal mode, `gc` in visual.
    case comment
    /// Enter (and c/i/a/o, as the plugin has it): edit the comment under the cursor,
    /// else start one.
    case activate
    case deleteComment
    case escape
    case send
    case toggleTree
    case focusTree, focusDiff
    case refresh
    case close
    /// ⌃P / `␣ff`: the fuzzy picker over the review's changed files.
    case findFiles
    /// `␣fg` / `␣/`: live grep over every changed line of the review.
    case findText
    /// `/` and `?`: search the open file forward / backward.
    case searchForward, searchBackward
    /// `n` / `N`: the next / previous match of the last search, in its direction.
    case searchNext, searchPrev
}

/// A key the parser reads: a character as typed (`j`, `G`, ` `, `]`) or a named key.
public enum ReviewKey: Sendable, Equatable {
    case char(Character)
    case ctrl(Character)
    case enter, escape, up, down, left, right, pageUp, pageDown, home, end
}

/// vim-style counts and multi-key sequences (`3j`, `gg`, `]c`, `gcc`, `<space>w`,
/// `<space>ff`). Space is the leader; `␣f` waits for its second key.
public struct ReviewKeyParser: Sendable {
    /// What has been typed toward a sequence so far, count digits included. Shown in
    /// the status bar like vim's `showcmd`.
    public private(set) var pending = ""

    public init() {}

    private static let normalSeqs = ["gg", "gt", "gT", "gcc", "]c", "[c", "]d", "[d", "dd",
                                     " w", " n", " e", " ff", " fg", " /"]
    private static let visualSeqs = ["gg", "gc", "]c", "[c", "]d", "[d", " w", " n", " e",
                                     " ff", " fg", " /"]

    public mutating func reset() { pending = "" }

    /// Feed one key; returns a command once a sequence completes. `visual` picks the
    /// sequence table (`gc` comments a selection; in normal mode it waits for `gcc`).
    public mutating func feed(_ key: ReviewKey, visual: Bool) -> ReviewKeyCommand? {
        let digits = String(pending.prefix { $0.isNumber })
        let prefix = String(pending.dropFirst(digits.count))
        let count = Int(digits) ?? 1
        let hasCount = !digits.isEmpty

        switch key {
        case .ctrl(let c):
            pending = ""
            switch c {
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            case "h": return .focusTree
            case "l": return .focusDiff
            case "c", "[": return .escape
            case "p": return .findFiles
            default: return nil
            }
        case .escape: pending = ""; return .escape
        case .enter: pending = ""; return .activate
        case .down: pending = ""; return .down(count)
        case .up: pending = ""; return .up(count)
        case .left: pending = ""; return .left
        case .right: pending = ""; return .right
        case .pageDown: pending = ""; return .halfPageDown
        case .pageUp: pending = ""; return .halfPageUp
        case .home: pending = ""; return .top
        case .end: pending = ""; return .bottom
        case .char(let c):
            if c.isNumber, prefix.isEmpty, !(c == "0" && digits.isEmpty) {
                pending.append(c)
                return nil
            }
            let seq = prefix + String(c)
            let table = visual ? Self.visualSeqs : Self.normalSeqs
            if table.contains(seq) {
                pending = ""
                return sequence(seq, count: count, hasCount: hasCount)
            }
            if table.contains(where: { $0.hasPrefix(seq) }) {
                pending = digits + seq
                return nil
            }
            pending = ""
            // A broken sequence is dropped, as in vim; only a fresh key acts.
            guard prefix.isEmpty else { return nil }
            return single(c, count: count, hasCount: hasCount)
        }
    }

    private func sequence(_ seq: String, count: Int, hasCount: Bool) -> ReviewKeyCommand? {
        switch seq {
        case "gg": return hasCount ? .goToLine(count) : .top
        case "gt": return .nextFile(count)
        case "gT": return .prevFile(count)
        case "gcc", "gc": return .comment
        case "]c": return .nextHunk(count)
        case "[c": return .prevHunk(count)
        case "]d": return .nextComment
        case "[d": return .prevComment
        case "dd": return .deleteComment
        case " w": return .send
        case " n": return .toggleTree
        case " e": return .focusTree
        case " ff": return .findFiles
        case " fg", " /": return .findText
        default: return nil
        }
    }

    private func single(_ c: Character, count: Int, hasCount: Bool) -> ReviewKeyCommand? {
        switch c {
        case "j": return .down(count)
        case "k": return .up(count)
        case "h": return .left
        case "l": return .right
        case "G": return hasCount ? .goToLine(count) : .bottom
        case "}": return .nextHunk(count)
        case "{": return .prevHunk(count)
        case "v", "V": return .toggleVisual
        case "c", "i", "a", "o": return .activate
        case "x": return .deleteComment
        case "q": return .close
        case "R": return .refresh
        case "/": return .searchForward
        case "?": return .searchBackward
        case "n": return .searchNext
        case "N": return .searchPrev
        default: return nil
        }
    }
}
