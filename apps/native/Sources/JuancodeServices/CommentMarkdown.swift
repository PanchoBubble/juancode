import Foundation

/// Pure comment-body preprocessing for the GitHub view. A GitHub markdown body
/// freely mixes inline HTML, and MarkdownUI prints any tag it doesn't recognise
/// verbatim (the literal `<strong>Waiting for</strong>` bug). So we translate
/// the common tags GitHub and its bots emit — `<strong>`/`<em>`/`<code>`,
/// headings, lists, `<a>`, `<img>` — into their markdown equivalents, then split
/// out `<details>`/`<summary>` blocks into native collapsible segments (their
/// summary labels come out already cleaned, since the translation runs over the
/// whole body first). Pure + unit-tested (`GhConversationTests`) — no UI, no gh.

/// One parsed piece of a comment body: a run of markdown, or a `<details>` block
/// whose inner content is parsed recursively (so nested disclosures nest).
public enum CommentSegment: Sendable, Equatable {
    case markdown(String)
    case details(summary: String, inner: [CommentSegment])
}

/// Clean the HTML out of `raw`, then split it into markdown runs and
/// `<details>` blocks.
public func parseCommentSegments(_ raw: String) -> [CommentSegment] {
    splitDetails(cleanCommentHTML(raw))
}

/// Translate the inline/block HTML GitHub bodies carry into markdown, strip the
/// noise wrappers, and leave `<details>`/`<summary>` for `splitDetails`.
/// Internal (not private) so the unit tests can exercise it directly.
func cleanCommentHTML(_ s: String) -> String {
    var out = s
    // <a href="url">text</a>  ->  [text](url), so MarkdownUI renders a real link
    // instead of printing the tag verbatim.
    out = out.replacingOccurrences(
        of: "<a\\s+[^>]*?href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
        with: "[$2]($1)",
        options: [.regularExpression, .caseInsensitive])
    // <img ... src="url" ... alt="text">  ->  ![text](url)
    out = out.replacingOccurrences(
        of: "<img\\s+[^>]*?src=[\"']([^\"']+)[\"'][^>]*?alt=[\"']([^\"']*)[\"'][^>]*/?>",
        with: "![$2]($1)",
        options: [.regularExpression, .caseInsensitive])

    // Paired inline emphasis/code -> markdown. Run before the wrapper strips so
    // the emphasis survives; nested content (already converted) is preserved.
    let paired: [(String, String)] = [
        ("<strong[^>]*>([\\s\\S]*?)</strong>", "**$1**"),
        ("<b[^>]*>([\\s\\S]*?)</b>", "**$1**"),
        ("<em[^>]*>([\\s\\S]*?)</em>", "*$1*"),
        ("<i[^>]*>([\\s\\S]*?)</i>", "*$1*"),
        ("<code[^>]*>([\\s\\S]*?)</code>", "`$1`"),
    ]
    for (pattern, replacement) in paired {
        out = out.replacingOccurrences(
            of: pattern, with: replacement,
            options: [.regularExpression, .caseInsensitive])
    }
    // <h1..6>text</h1..6> -> an ATX heading on its own line.
    for level in 1...6 {
        let hashes = String(repeating: "#", count: level)
        out = out.replacingOccurrences(
            of: "<h\(level)[^>]*>([\\s\\S]*?)</h\(level)>",
            with: "\n\n\(hashes) $1\n\n",
            options: [.regularExpression, .caseInsensitive])
    }
    // List items -> "- item"; the containers become blank lines below.
    out = out.replacingOccurrences(
        of: "<li[^>]*>([\\s\\S]*?)</li>", with: "\n- $1",
        options: [.regularExpression, .caseInsensitive])

    let subs: [(String, String)] = [
        ("<!--[\\s\\S]*?-->", ""),              // HTML comments
        ("<br\\s*/?>", "\n"),                   // line breaks
        ("</?p\\s*>", "\n\n"),                  // paragraph wrappers
        ("</?su[bp]\\s*>", ""),                 // <sub>/<sup> wrappers
        ("</?(?:ul|ol)[^>]*>", "\n"),           // list containers
        ("</?blockquote[^>]*>", "\n"),          // quote wrappers
        // Tables: no faithful markdown-table conversion (needs a header
        // separator row), so flatten to readable rows — one line per <tr>,
        // cells space-separated — rather than leaving raw tags on screen.
        ("</tr\\s*>", "\n"),
        ("<tr[^>]*>", ""),
        ("</?t(?:head|body|able)[^>]*>", "\n"),
        ("</?t[hd][^>]*>", " "),
        ("</?(?:span|div|kbd|font)[^>]*>", ""), // stray inline wrappers bots emit
    ]
    for (pattern, replacement) in subs {
        out = out.replacingOccurrences(
            of: pattern, with: replacement,
            options: [.regularExpression, .caseInsensitive])
    }
    return out
}

/// Split cleaned text into markdown runs and `<details>` blocks (balanced,
/// nesting-aware).
func splitDetails(_ text: String) -> [CommentSegment] {
    var segments: [CommentSegment] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        guard let open = text.range(of: "<details", options: .caseInsensitive,
                                    range: idx..<text.endIndex) else {
            appendMarkdown(text[idx...], to: &segments)
            break
        }
        appendMarkdown(text[idx..<open.lowerBound], to: &segments)
        guard let openTagEnd = text.range(of: ">", range: open.upperBound..<text.endIndex) else {
            appendMarkdown(text[open.lowerBound...], to: &segments)
            break
        }
        let contentStart = openTagEnd.upperBound
        guard let close = matchingDetailsClose(text, from: contentStart) else {
            // Unbalanced <details>: treat everything after it as the inner body.
            segments.append(makeDetails(String(text[contentStart...])))
            break
        }
        segments.append(makeDetails(String(text[contentStart..<close.lowerBound])))
        idx = close.upperBound
    }
    return segments
}

/// Find the `</details>` that closes the block opened just before `start`,
/// accounting for nested `<details>`. Returns the full `</details ... >` range.
private func matchingDetailsClose(_ text: String, from start: String.Index) -> Range<String.Index>? {
    var depth = 1
    var cursor = start
    while cursor < text.endIndex {
        let openR = text.range(of: "<details", options: .caseInsensitive,
                               range: cursor..<text.endIndex)
        guard let closeR = text.range(of: "</details", options: .caseInsensitive,
                                      range: cursor..<text.endIndex) else { return nil }
        if let open = openR, open.lowerBound < closeR.lowerBound {
            depth += 1
            cursor = open.upperBound
        } else {
            depth -= 1
            if depth == 0 {
                let gt = text.range(of: ">", range: closeR.upperBound..<text.endIndex)
                return closeR.lowerBound..<(gt?.upperBound ?? text.endIndex)
            }
            cursor = closeR.upperBound
        }
    }
    return nil
}

/// Build a `.details` segment: pull the leading `<summary>` (if any) as the
/// label, recursively parse the remaining inner body.
private func makeDetails(_ inner: String) -> CommentSegment {
    var summary = "Details"
    var rest = inner
    if let sOpen = inner.range(of: "<summary", options: .caseInsensitive),
       let sTagEnd = inner.range(of: ">", range: sOpen.upperBound..<inner.endIndex),
       let sClose = inner.range(of: "</summary>", options: .caseInsensitive,
                                range: sTagEnd.upperBound..<inner.endIndex) {
        let label = inner[sTagEnd.upperBound..<sClose.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { summary = label }
        rest.removeSubrange(sOpen.lowerBound..<sClose.upperBound)
    }
    return .details(summary: summary, inner: splitDetails(rest))
}

private func appendMarkdown(_ slice: Substring, to segments: inout [CommentSegment]) {
    let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { segments.append(.markdown(trimmed)) }
}
