import CoreGraphics
import Foundation
import JuancodeCore

/// Pure unified-diff parsing for the native ChangesPanel — the SwiftUI analogue of
/// the web's `react-diff-view` `parseDiff` + change-key machinery. Given the raw
/// per-file unified diff that `getDiff` already produces, it yields hunks of typed
/// lines, each carrying its old/new line numbers and a stable anchor (side+line)
/// so inline comments can attach to a line on either side. No git here — this is
/// string parsing only, which is why it lives in its own unit-tested module.

/// One line within a parsed diff hunk.
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context   // unchanged line present on both sides
        case insert    // added line (new side only)
        case delete    // removed line (old side only)
    }
    public let kind: Kind
    /// 1-based line number on the old side, or nil for inserts.
    public let oldLine: Int?
    /// 1-based line number on the new side, or nil for deletes.
    public let newLine: Int?
    /// The line content without its leading +/-/space marker.
    public let text: String

    public init(kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.kind = kind; self.oldLine = oldLine; self.newLine = newLine; self.text = text
    }

    /// The side+line a comment anchors to: the new line for inserts/context, else
    /// the old line for deletes. Mirrors the web `anchorOf`.
    public var anchor: (side: CommentSide, line: Int)? {
        if let n = newLine { return (.new, n) }
        if let o = oldLine { return (.old, o) }
        return nil
    }
}

/// A single `@@ … @@` hunk: its header text plus the lines it contains.
public struct DiffHunk: Sendable, Equatable {
    public let header: String
    public let lines: [DiffLine]
    public init(header: String, lines: [DiffLine]) {
        self.header = header; self.lines = lines
    }
}

/// Parse a file's unified diff into hunks. Lines outside any hunk (the `diff --git`,
/// `index`, `---`/`+++` file headers) are skipped. Tolerant of a trailing
/// "\ No newline at end of file" marker. Returns `[]` when there are no hunks.
public func parseUnifiedDiff(_ diff: String) -> [DiffHunk] {
    guard !diff.isEmpty else { return [] }
    var hunks: [DiffHunk] = []
    var header: String? = nil
    var lines: [DiffLine] = []
    var oldNo = 0
    var newNo = 0

    func flush() {
        if let h = header { hunks.append(DiffHunk(header: h, lines: lines)) }
        header = nil
        lines = []
    }

    for raw in diff.components(separatedBy: "\n") {
        if raw.hasPrefix("@@") {
            flush()
            header = raw
            let (o, n) = parseHunkStarts(raw)
            oldNo = o
            newNo = n
            continue
        }
        guard header != nil else { continue } // pre-hunk file headers
        if raw.hasPrefix("\\") { continue }    // "\ No newline at end of file"
        let marker = raw.first
        let body = raw.isEmpty ? "" : String(raw.dropFirst())
        switch marker {
        case "+":
            lines.append(DiffLine(kind: .insert, oldLine: nil, newLine: newNo, text: body))
            newNo += 1
        case "-":
            lines.append(DiffLine(kind: .delete, oldLine: oldNo, newLine: nil, text: body))
            oldNo += 1
        case " ":
            lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: body))
            oldNo += 1
            newNo += 1
        default:
            // A blank line inside a hunk is an empty context line ("" with no marker).
            if raw.isEmpty {
                lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: ""))
                oldNo += 1
                newNo += 1
            }
            // Anything else (e.g. a stray header line) is ignored.
        }
    }
    flush()
    return hunks
}

// MARK: - multi-file patch splitting (PR diffs, juancode-49w)

/// Per-file cap mirroring `Git.swift`'s `MAX_DIFF_BYTES`: a single file's diff
/// larger than this is summarized (counts kept, body dropped), not carried.
private let MAX_FILE_DIFF_BYTES = 400_000

/// Split a combined unified diff (e.g. `gh pr diff` / `git diff`, many files in
/// one stream) into per-file `DiffFile`s — the same wire shape `getDiff` produces,
/// so a PR's diff can be loaded into the ChangesPanel exactly like the working
/// tree (juancode-49w). Pure string parsing — no git/gh — which is why it lives
/// here. Lines before the first `diff --git` header (any tool preamble) are
/// ignored. Returns `[]` for an empty/headerless patch.
public func parseMultiFileDiff(_ patch: String) -> [DiffFile] {
    guard !patch.isEmpty else { return [] }
    var chunks: [[String]] = []
    var current: [String]? = nil
    for line in patch.components(separatedBy: "\n") {
        if line.hasPrefix("diff --git ") {
            if let c = current { chunks.append(c) }
            current = [line]
        } else if current != nil {
            current?.append(line)
        }
        // else: preamble before the first file header — skip.
    }
    if let c = current { chunks.append(c) }
    return chunks.compactMap(diffFile(fromChunk:))
}

/// Build one `DiffFile` from a single file's chunk (its `diff --git` header
/// through the line before the next header). Returns nil if no path can be found.
private func diffFile(fromChunk lines: [String]) -> DiffFile? {
    var oldMarkerPath: String? = nil
    var newMarkerPath: String? = nil
    var renameFrom: String? = nil
    var renameTo: String? = nil
    var sawNewFile = false
    var sawDeleted = false
    var binary = false

    for line in lines {
        if line.hasPrefix("new file mode") { sawNewFile = true }
        else if line.hasPrefix("deleted file mode") { sawDeleted = true }
        else if line.hasPrefix("rename from ") { renameFrom = String(line.dropFirst("rename from ".count)) }
        else if line.hasPrefix("rename to ") { renameTo = String(line.dropFirst("rename to ".count)) }
        else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true }
        else if line.hasPrefix("--- ") {
            if let p = pathFromFileMarker(String(line.dropFirst(4))) { oldMarkerPath = p }
        } else if line.hasPrefix("+++ ") {
            if let p = pathFromFileMarker(String(line.dropFirst(4))) { newMarkerPath = p }
        }
    }

    let status: FileStatus
    var path: String?
    var oldPath: String? = nil
    if let to = renameTo {
        status = .renamed
        path = to
        oldPath = renameFrom
    } else if sawNewFile {
        status = .added
        path = newMarkerPath
    } else if sawDeleted {
        status = .deleted
        path = oldMarkerPath
    } else {
        status = .modified
        path = newMarkerPath ?? oldMarkerPath
    }
    // Fall back to the `diff --git a/… b/…` header (handles pure renames / binary
    // files that carry no `---`/`+++` lines).
    let resolved = path ?? pathFromGitHeader(lines.first ?? "")
    guard let finalPath = resolved, !finalPath.isEmpty else { return nil }

    let (additions, deletions) = countAddDel(lines)
    let text = lines.joined(separator: "\n")
    let tooLarge = text.utf16.count > MAX_FILE_DIFF_BYTES
    return DiffFile(
        path: finalPath,
        oldPath: oldPath,
        status: status,
        additions: binary ? 0 : additions,
        deletions: binary ? 0 : deletions,
        binary: binary,
        diff: (binary || tooLarge) ? "" : text,
        truncated: tooLarge)
}

/// Strip a `--- `/`+++ ` marker down to its path: drops a leading `a/`/`b/`, maps
/// `/dev/null` (add/delete sentinel) to nil. Trims only the surrounding spaces.
private func pathFromFileMarker(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s == "/dev/null" { return nil }
    if s.hasPrefix("a/") || s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
    return s.isEmpty ? nil : s
}

/// Best-effort path from a `diff --git a/<old> b/<new>` header — used only when a
/// chunk has no usable `---`/`+++` lines. Splits on the ` b/` separator, which is
/// unambiguous for the common case of paths without spaces.
private func pathFromGitHeader(_ header: String) -> String? {
    guard header.hasPrefix("diff --git ") else { return nil }
    let rest = String(header.dropFirst("diff --git ".count))
    if let r = rest.range(of: " b/") {
        let newPart = String(rest[r.upperBound...])
        return newPart.isEmpty ? nil : newPart
    }
    return nil
}

/// Count added/removed content lines in a file chunk, ignoring the `+++`/`---`
/// file-header lines (mirrors `Git.swift`'s `countChanges`).
private func countAddDel(_ lines: [String]) -> (additions: Int, deletions: Int) {
    var additions = 0
    var deletions = 0
    for line in lines {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { additions += 1 }
        else if line.hasPrefix("-") && !line.hasPrefix("---") { deletions += 1 }
    }
    return (additions, deletions)
}

/// Extract the old/new starting line numbers from a `@@ -a,b +c,d @@` header.
/// Defaults the counts to line 1 when a hunk omits them (`@@ -a +c @@`).
private func parseHunkStarts(_ header: String) -> (old: Int, new: Int) {
    // Find the "-" and "+" groups between the leading and trailing "@@".
    var old = 1
    var new = 1
    let tokens = header.split(separator: " ")
    for t in tokens {
        if t.hasPrefix("-") {
            old = Int(t.dropFirst().split(separator: ",").first ?? "1") ?? 1
        } else if t.hasPrefix("+") {
            new = Int(t.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
    }
    return (old, new)
}

/// Map a vertical drag offset (in points, within the diff line stack's coordinate
/// space) to the 0-based index of the line row under it, given a uniform per-row
/// `rowHeight`. Clamps into `[0, count - 1]` so a drag that overshoots the top or
/// bottom of the stack still resolves to the first/last row. Returns nil only when
/// there are no rows. Kept pure so the drag-select hit-testing is unit-testable
/// without a running SwiftUI view (juancode-eba).
public func diffLineIndex(forOffset y: CGFloat, rowHeight: CGFloat, count: Int) -> Int? {
    guard count > 0, rowHeight > 0 else { return nil }
    let raw = Int((y / rowHeight).rounded(.down))
    return Swift.min(Swift.max(raw, 0), count - 1)
}

/// Normalize a drag's anchor/current line indices into an ordered, inclusive range,
/// so dragging upward (current < anchor) yields the same `lower...upper` as dragging
/// downward. Pure helper for the drag-select gesture (juancode-eba).
public func normalizedLineRange(anchor: Int, current: Int) -> ClosedRange<Int> {
    Swift.min(anchor, current)...Swift.max(anchor, current)
}

/// A human label for a comment's anchored range, e.g. "L10" or "L10–14 (old)".
/// Mirrors the web `rangeLabel`.
public func commentRangeLabel(side: CommentSide, line: Int, endLine: Int) -> String {
    let lines = line == endLine ? "L\(line)" : "L\(line)–\(endLine)"
    return side == .old ? "\(lines) (old)" : lines
}

/// Compose every pending comment (+ an optional closing note) into one prompt for
/// the agent, grouped by file in diff order. Mirrors the web `composeReviewPrompt`
/// so the native "submit review" injects the same text the web pastes into the pty.
public func composeReviewPrompt(files: [DiffFile], comments: [DiffComment], finalNote: String) -> String {
    var byFile: [String: [DiffComment]] = [:]
    var fileOrder: [String] = []
    for c in comments {
        if byFile[c.file] == nil { byFile[c.file] = []; fileOrder.append(c.file) }
        byFile[c.file]?.append(c)
    }
    var out: [String] = ["Here are my review comments on the current working-tree changes:", ""]
    // Walk files in diff order, then any commented files not in the current diff.
    var order = files.map(\.path)
    order.append(contentsOf: fileOrder)
    var seen = Set<String>()
    for path in order {
        if seen.contains(path) { continue }
        seen.insert(path)
        guard let list = byFile[path], !list.isEmpty else { continue }
        out.append("### \(path)")
        for c in list.sorted(by: { $0.line < $1.line }) {
            // Indent any continuation lines so multi-line bodies stay under the bullet.
            let body = c.body.replacingOccurrences(of: "\n", with: "\n  ")
            out.append("- \(commentRangeLabel(side: c.side, line: c.line, endLine: c.endLine)): \(body)")
        }
        out.append("")
    }
    let note = finalNote.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty { out.append(note) }
    // .trimEnd() — drop trailing whitespace/newlines.
    return out.joined(separator: "\n").replacingOccurrences(
        of: "\\s+$", with: "", options: .regularExpression)
}
