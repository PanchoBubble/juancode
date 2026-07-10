import Foundation
import JuancodeCore

/// Word-level intraline diffing for the ChangesPanel: given a removed line paired
/// with the added line that replaced it, compute the character ranges that actually
/// changed on each side so the view can tint just those spans (GitHub-style) instead
/// of the whole line. Pure string work — no SwiftUI — so it's unit-tested here.

/// Pair each removed line with the added line that replaced it, positionally, within
/// a hunk. A maximal run of consecutive deletes immediately followed by a run of
/// inserts is zipped index-for-index (the i-th delete with the i-th insert). Context
/// or a lone insert/delete run breaks the pairing. Returns `(deleteIndex, insertIndex)`
/// pairs as indices into the passed flat-line list.
public func intralinePairs(_ lines: [DiffLine]) -> [(delete: Int, insert: Int)] {
    var pairs: [(delete: Int, insert: Int)] = []
    var i = 0
    while i < lines.count {
        guard lines[i].kind == .delete else { i += 1; continue }
        // Gather the delete run.
        let delStart = i
        while i < lines.count, lines[i].kind == .delete { i += 1 }
        let deletes = Array(delStart..<i)
        // Gather the insert run immediately following it.
        let insStart = i
        while i < lines.count, lines[i].kind == .insert { i += 1 }
        let inserts = Array(insStart..<i)
        for k in 0..<Swift.min(deletes.count, inserts.count) {
            pairs.append((delete: deletes[k], insert: inserts[k]))
        }
    }
    return pairs
}

/// Lines longer than this skip intraline diffing — the token LCS is O(n·m), so a very
/// long minified line would stall. The whole line still renders; it just isn't sub-tinted.
private let maxIntralineLength = 2000

/// The changed character ranges on each side of a removed/added line pair. Ranges are
/// character offsets into `old` / `new` respectively, merged where adjacent. When the
/// lines are identical both are empty; when one side is empty the other's whole range
/// is returned.
public func intralineWordRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
    if old == new { return ([], []) }
    let oldCount = old.count
    let newCount = new.count
    if old.isEmpty { return ([], newCount > 0 ? [0..<newCount] : []) }
    if new.isEmpty { return (oldCount > 0 ? [0..<oldCount] : [], []) }
    if oldCount > maxIntralineLength || newCount > maxIntralineLength {
        return ([0..<oldCount], [0..<newCount])
    }

    let oldTokens = tokenize(old)
    let newTokens = tokenize(new)
    let (oldMatched, newMatched) = lcsMatches(oldTokens.map(\.text), newTokens.map(\.text))

    let oldRanges = mergedRanges(tokens: oldTokens, matched: oldMatched)
    let newRanges = mergedRanges(tokens: newTokens, matched: newMatched)
    return (oldRanges, newRanges)
}

// MARK: - internals

/// A token plus its character offset range in the source line.
private struct Token { let text: String; let range: Range<Int> }

/// Split a line into tokens: maximal runs of identifier characters (letters, digits,
/// `_`) are one token; every other character is its own token. This keeps word
/// boundaries meaningful while letting punctuation/whitespace align on its own.
private func tokenize(_ s: String) -> [Token] {
    var out: [Token] = []
    var idx = 0
    var wordStart: Int? = nil
    let chars = Array(s)
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    for c in chars {
        if isWord(c) {
            if wordStart == nil { wordStart = idx }
        } else {
            if let ws = wordStart {
                out.append(Token(text: String(chars[ws..<idx]), range: ws..<idx))
                wordStart = nil
            }
            out.append(Token(text: String(c), range: idx..<(idx + 1)))
        }
        idx += 1
    }
    if let ws = wordStart {
        out.append(Token(text: String(chars[ws..<idx]), range: ws..<idx))
    }
    return out
}

/// Standard LCS over two token-string arrays, returning per-index booleans marking
/// which tokens are part of the common subsequence (i.e. unchanged) on each side.
private func lcsMatches(_ a: [String], _ b: [String]) -> (a: [Bool], b: [Bool]) {
    let n = a.count, m = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : Swift.max(dp[i + 1][j], dp[i][j + 1])
        }
    }
    var aMatched = [Bool](repeating: false, count: n)
    var bMatched = [Bool](repeating: false, count: m)
    var i = 0, j = 0
    while i < n, j < m {
        if a[i] == b[j] {
            aMatched[i] = true; bMatched[j] = true
            i += 1; j += 1
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    return (aMatched, bMatched)
}

/// Build character ranges over the unmatched (changed) tokens, merging ranges that
/// touch so a run of changed tokens becomes a single tinted span.
private func mergedRanges(tokens: [Token], matched: [Bool]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for (i, token) in tokens.enumerated() where !matched[i] {
        if let last = ranges.last, last.upperBound == token.range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound..<token.range.upperBound
        } else {
            ranges.append(token.range)
        }
    }
    return ranges
}
