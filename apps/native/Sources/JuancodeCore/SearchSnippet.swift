import Foundation

/// The one convention a search snippet is written in, and the two halves that
/// speak it: `searchSnippet` cuts the text around a match and brackets it,
/// `parseSearchSnippet` splits those brackets back into runs a view can emphasise.
///
/// In JuancodeCore rather than in a store or a service because both ends of the
/// wire produce this shape now. It used to come out of the mirror's fts5
/// `snippet()`, which is gone (juancode-5bwj: that index was a second copy of every
/// scrollback); today the daemon cuts its own in `juancoded-persistence/src/search.rs`
/// and the mirror cuts one here, and the panel cannot tell which it got. A snippet
/// that arrived over the socket and a snippet built locally have to read the same or
/// one result list looks like two search engines.

/// One contiguous run of a search snippet: plain text or a highlighted match.
public struct SnippetRun: Sendable, Equatable {
    public let text: String
    public let highlighted: Bool

    public init(text: String, highlighted: Bool) {
        self.text = text
        self.highlighted = highlighted
    }
}

/// Split `snippet` into runs, turning the store's `[term]` markers into
/// `highlighted` runs and leaving everything else as plain text. Mirrors the web
/// regex `/\[([^\]]*)\]/g`: a `[`…`]` pair (no nested `]`) becomes a highlight of
/// its inner text; an unmatched `[` is treated as literal plain text.
public func parseSearchSnippet(_ snippet: String) -> [SnippetRun] {
    var runs: [SnippetRun] = []
    var plain = ""

    func flushPlain() {
        if !plain.isEmpty {
            runs.append(SnippetRun(text: plain, highlighted: false))
            plain = ""
        }
    }

    let chars = Array(snippet)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]") {
            // [term] → highlighted run of the inner text (which may be empty).
            flushPlain()
            let inner = String(chars[(i + 1)..<close])
            runs.append(SnippetRun(text: inner, highlighted: true))
            i = close + 1
        } else {
            plain.append(c)
            i += 1
        }
    }
    flushPlain()
    return runs
}

/// How much text to keep either side of the match. The same 80 as `SNIPPET_WINDOW`
/// in the daemon's `search.rs`, so the two ends cut to the same width.
private let snippetWindow = 80

/// The text around the first occurrence of `query` in `haystack`, bracketed, with an
/// ellipsis on whichever side was cut — nil when the query is not in there at all.
///
/// Over UTF-8 bytes rather than `Character`s, because the haystack here is a whole
/// session's scrollback (up to 256KiB) and materialising that as a `[Character]` to
/// find one word in it costs more than the search that found the session did.
///
/// ASCII case folding, and that is not a shortcut: it is exactly what SQLite's `LIKE`
/// does, and `LIKE` is what found this hit, so folding the same way lands on the
/// occurrence that actually matched. `lowercased()` folds characters `LIKE` leaves
/// alone and would point somewhere else in the text.
public func searchSnippet(in haystack: String, matching query: String) -> String? {
    let text = Array(haystack.utf8)
    let needle = Array(query.utf8).map(asciiFolded)
    guard !needle.isEmpty, text.count >= needle.count else { return nil }

    let folded = text.map(asciiFolded)
    var found: Int?
    for start in 0...(folded.count - needle.count)
    where folded[start] == needle[0] && Array(folded[start..<(start + needle.count)]) == needle {
        found = start
        break
    }
    // The first byte of a needle taken from a `String` is never a UTF-8 continuation
    // byte, and a continuation byte is the only way a match could land mid-character,
    // so `at` and `end` are already boundaries. Only the window edges need walking.
    guard let at = found else { return nil }
    let end = at + needle.count
    let start = floorBoundary(text, at - snippetWindow)
    let stop = ceilBoundary(text, end + snippetWindow)

    var out = ""
    if start > 0 { out += "…" }
    out += trimLeading(collapse(text[start..<at]))
    out += "[" + decode(text[at..<end]) + "]"
    out += trimTrailing(collapse(text[end..<stop]))
    if stop < text.count { out += "…" }
    return out
}

/// `A`–`Z` to `a`–`z` and nothing else, which is the whole of SQLite's `LIKE` folding.
private func asciiFolded(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
}

/// One line, so a snippet cut out of a multi-line prompt is still one row tall.
/// Before the decode, not after: these are all single-byte, so swapping them here
/// costs a byte map instead of a second walk over the decoded characters.
private func collapse(_ bytes: ArraySlice<UInt8>) -> String {
    decode(ArraySlice(bytes.map { $0 == 0x0A || $0 == 0x0D || $0 == 0x09 ? 0x20 : $0 }))
}

/// Lossy on purpose: a scrollback ring is cut at a byte boundary, not a character one.
private func decode(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
}

private func trimLeading(_ text: String) -> String {
    String(text.drop { $0 == " " })
}

private func trimTrailing(_ text: String) -> String {
    var out = text
    while out.last == " " { out.removeLast() }
    return out
}

private func floorBoundary(_ bytes: [UInt8], _ at: Int) -> Int {
    var i = max(0, at)
    while i > 0 && bytes[i] & 0xC0 == 0x80 { i -= 1 }
    return i
}

private func ceilBoundary(_ bytes: [UInt8], _ at: Int) -> Int {
    var i = min(bytes.count, at)
    while i < bytes.count && bytes[i] & 0xC0 == 0x80 { i += 1 }
    return i
}
