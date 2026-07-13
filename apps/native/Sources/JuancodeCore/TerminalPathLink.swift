import Foundation

/// Extracts a clickable file reference (`path` with an optional 1-based `line`) from a
/// rendered terminal line, so ⌘-clicking agent output like
/// `apps/native/Sources/App.swift:830` can open that file at that line.
///
/// A token qualifies only when it looks like a path — it contains a directory separator
/// or carries an explicit `:line` — which keeps prose ("e.g.", "vs.") and version-ish
/// runs from resolving to stray files. URLs are skipped (those open in a browser).
public enum TerminalPathLink {
    /// Parse the first qualifying path token, preferring the one whose character span
    /// covers `preferColumn` when the line holds several (the clicked column).
    public static func parse(in line: String, preferColumn: Int) -> (path: String, line: Int?)? {
        let pattern = #"([~\w./+@\-]*[/.][~\w./+@\-]*)(?::(\d+))?(?::\d+)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        var candidates: [(range: NSRange, path: String, line: Int?)] = []
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let pathRange = m.range(at: 1)
            guard pathRange.location != NSNotFound else { continue }
            var path = ns.substring(with: pathRange)
            if path.contains("://") { continue } // URLs go through the browser path
            // A URL splits at its scheme colon, leaving "//host/path" as the match — skip
            // that tail (a real file path never starts with "//", and one directly after
            // a ":" is the authority of a scheme like https:).
            if path.hasPrefix("//") { continue }
            let prevIsColon = pathRange.location > 0
                && ns.substring(with: NSRange(location: pathRange.location - 1, length: 1)) == ":"
            if prevIsColon { continue }
            // Trim trailing punctuation the run may have swept up (e.g. a sentence dot).
            while let last = path.last, ".,:;)]}".contains(last) { path.removeLast() }
            var lineNo: Int?
            let lineRange = m.range(at: 2)
            if lineRange.location != NSNotFound { lineNo = Int(ns.substring(with: lineRange)) }
            // Needs a directory separator or an explicit :line to count as a path.
            guard path.contains("/") || lineNo != nil else { continue }
            guard !path.isEmpty else { continue }
            candidates.append((m.range, path, lineNo))
        }
        guard !candidates.isEmpty else { return nil }
        let hit = candidates.first { NSLocationInRange(preferColumn, $0.range) } ?? candidates[0]
        return (hit.path, hit.line)
    }
}
