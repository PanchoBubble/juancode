import Foundation

public enum ReviewContextError: LocalizedError {
    case mismatch, tooLarge
    public var errorDescription: String? {
        switch self {
        case .mismatch: return "The file no longer matches this diff. Refresh the review and try again."
        case .tooLarge: return "This file is too large to expand (20,000 lines maximum)."
        }
    }
}

/// Fill omitted ranges from the after-change document, retaining all original
/// side/line anchors. Validate visible lines before combining two snapshots.
public func reviewExpandedRows(for file: DiffFile, source: String) throws -> [ReviewRow] {
    var document = source.components(separatedBy: "\n")
    if document.last == "" { document.removeLast() }
    guard document.count <= 20_000 else { throw ReviewContextError.tooLarge }
    var rows: [ReviewRow] = []
    var old = 1, new = 1
    func appendContext(until end: Int) throws {
        guard end >= new, end <= document.count + 1 else { throw ReviewContextError.mismatch }
        while new < end {
            rows.append(.line(DiffLine(kind: .context, oldLine: old, newLine: new,
                                      text: document[new - 1].replacingOccurrences(of: "\t", with: "    "))))
            old += 1; new += 1
        }
    }
    for hunk in parseUnifiedDiff(file.diff) {
        let parts = hunk.header.split(separator: " ")
        guard parts.count >= 3 else { throw ReviewContextError.mismatch }
        func range(_ part: Substring) throws -> (Int, Int) {
            let fields = part.dropFirst().split(separator: ",")
            guard let start = fields.first.flatMap({ Int($0) }) else { throw ReviewContextError.mismatch }
            return (start, fields.count > 1 ? (Int(fields[1]) ?? -1) : 1)
        }
        let (oldStart, oldCount) = try range(parts[1])
        let (newStart, newCount) = try range(parts[2])
        let nextOld = oldStart + (oldCount == 0 ? 1 : 0)
        let nextNew = newStart + (newCount == 0 ? 1 : 0)
        guard oldCount >= 0, newCount >= 0, nextOld - old == nextNew - new else {
            throw ReviewContextError.mismatch
        }
        try appendContext(until: nextNew)
        rows.append(.hunk(hunk.header))
        var usedOld = 0, usedNew = 0
        for line in hunk.lines {
            // The tolerant parser may include the patch's final empty separator.
            if usedOld == oldCount && usedNew == newCount { break }
            if line.kind != .delete {
                guard document.indices.contains(new - 1), document[new - 1] == line.text,
                      line.newLine == new else { throw ReviewContextError.mismatch }
                new += 1; usedNew += 1
            }
            if line.kind != .insert {
                guard line.oldLine == old else { throw ReviewContextError.mismatch }
                old += 1; usedOld += 1
            }
            guard usedOld <= oldCount, usedNew <= newCount else { throw ReviewContextError.mismatch }
            rows.append(.line(DiffLine(kind: line.kind, oldLine: line.oldLine, newLine: line.newLine,
                                      text: line.text.replacingOccurrences(of: "\t", with: "    "))))
        }
        guard usedOld == oldCount, usedNew == newCount else { throw ReviewContextError.mismatch }
    }
    try appendContext(until: document.count + 1)
    guard rows.count <= 20_000 else { throw ReviewContextError.tooLarge }
    return rows
}

/// Character offsets (not UTF-16) match the attributed row's visible cursor.
public func reviewColumn(in text: String, from column: Int, command: ReviewKeyCommand) -> Int {
    let chars = Array(text)
    let last = max(0, chars.count - 1)
    var at = min(max(0, column), last)
    func kind(_ i: Int) -> Int {
        let c = chars[i]
        return c.isWhitespace ? 0 : (c.isLetter || c.isNumber || c == "_" ? 1 : 2)
    }
    switch command {
    case .left: return max(0, at - 1)
    case .right: return min(last, at + 1)
    case .columns(let count): return at + min(max(-at, count), last - at)
    case .lineStart: return 0
    case .lineEnd: return last
    case .wordForward(let count):
        for _ in 0..<min(max(1, count), chars.count) {
            let initial = kind(at)
            while at < last && kind(at) == initial { at += 1 }
            while at < last && kind(at) == 0 { at += 1 }
        }
    case .wordBackward(let count):
        for _ in 0..<min(max(1, count), chars.count) {
            at = max(0, at - 1)
            while at > 0 && kind(at) == 0 { at -= 1 }
            let initial = kind(at)
            while at > 0 && kind(at - 1) == initial { at -= 1 }
        }
    case .wordEnd(let count):
        for _ in 0..<min(max(1, count), chars.count) {
            at = min(last, at + 1)
            while at < last && kind(at) == 0 { at += 1 }
            let initial = kind(at)
            while at < last && kind(at + 1) == initial { at += 1 }
        }
    default: break
    }
    return at
}
