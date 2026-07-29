import Foundation

/// Structure for the failing-CI text `getFailedCheckLogs` returns, so the GitHub
/// view can render a red build the way the Actions web UI does — folded groups,
/// highlighted error lines, timestamps out of the way — instead of a flat 20k-char
/// dump that sends you to the site to find the one line that matters.
///
/// Pure string parsing, no `gh`, which is why it lives beside `DiffParse.swift`
/// and is unit-tested directly. Colour is kept as raw SGR codes here; mapping them
/// to `Color` is the view's job (same split as `VimSyntaxPalette`).
///
/// The grammar comes from two places. `gh run view --log-failed` prints one line
/// per log line as `<job>\t<step>\t<raw line>`, where the raw line starts with an
/// RFC3339 timestamp. The raw line then carries GitHub Actions' own log commands
/// (`##[group]` / `##[endgroup]` / `##[error]` / …) and ANSI SGR escapes — the same
/// two layers GitHub Desktop parses in `app/src/lib/actions-log-parser` (MIT).

// MARK: - wire types

/// A run of text sharing one set of ANSI attributes.
public struct ActionsLogSpan: Sendable, Equatable {
    public let text: String
    /// Raw SGR foreground code (30–37 / 90–97), or nil for the default colour.
    public let fg: Int?
    public let bold: Bool
    public init(text: String, fg: Int? = nil, bold: Bool = false) {
        self.text = text; self.fg = fg; self.bold = bold
    }
}

/// What an Actions log command said about a line, when it said anything.
public enum ActionsLogSeverity: String, Sendable, Equatable {
    case plain, command, debug, notice, warning, error
}

/// One log line: where it came from, when, how loud it is, and its text already
/// split into ANSI-attributed spans (marker and timestamp stripped).
public struct ActionsLogLine: Sendable, Equatable, Identifiable {
    public let id: Int
    public let severity: ActionsLogSeverity
    /// The line's timestamp, or nil when it had none / it wouldn't parse.
    public let timestamp: Date?
    public let spans: [ActionsLogSpan]
    public init(id: Int, severity: ActionsLogSeverity, timestamp: Date?, spans: [ActionsLogSpan]) {
        self.id = id; self.severity = severity; self.timestamp = timestamp; self.spans = spans
    }

    /// The line as plain text — for search, copy, and the collapsed summary.
    public var text: String { spans.map(\.text).joined() }
}

/// A `##[group]` … `##[endgroup]` fold, or the implicit group holding the lines
/// that sat outside any fold (`title` empty, `foldable` false).
public struct ActionsLogGroup: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let foldable: Bool
    public let lines: [ActionsLogLine]
    public init(id: Int, title: String, foldable: Bool, lines: [ActionsLogLine]) {
        self.id = id; self.title = title; self.foldable = foldable; self.lines = lines
    }

    /// True when any line in the group is an error — what decides whether the fold
    /// starts open.
    public var hasError: Bool { lines.contains { $0.severity == .error } }
}

/// All the log for one job step, in the order gh emitted it.
public struct ActionsLogSection: Sendable, Equatable, Identifiable {
    public let id: Int
    /// The workflow run id this step belongs to, when the text carried one.
    public let runId: String?
    public let job: String
    public let step: String
    public let groups: [ActionsLogGroup]
    public init(id: Int, runId: String?, job: String, step: String, groups: [ActionsLogGroup]) {
        self.id = id; self.runId = runId; self.job = job; self.step = step; self.groups = groups
    }

    public var hasError: Bool { groups.contains(where: \.hasError) }
    /// Every error line in the step — the "why is CI red" summary, without a fold
    /// to open first.
    public var errorLines: [ActionsLogLine] {
        groups.flatMap(\.lines).filter { $0.severity == .error }
    }
}

/// A parsed failing-CI log.
public struct ActionsLog: Sendable, Equatable {
    public let sections: [ActionsLogSection]
    /// True when the text carried `getFailedCheckLogs`' truncation marker, i.e. the
    /// head was dropped to fit the cap.
    public let truncated: Bool
    public init(sections: [ActionsLogSection], truncated: Bool) {
        self.sections = sections; self.truncated = truncated
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var errorLines: [ActionsLogLine] { sections.flatMap(\.errorLines) }
}

// MARK: - parsing

/// `getFailedCheckLogs`' per-run banner, e.g. `===== run 123 (failed steps) =====`.
private let runBannerPrefix = "===== run "

/// Parse the failing-step text `getFailedCheckLogs` produces into steps → folds →
/// lines. Tolerant by construction: a line that doesn't match the `job\tstep\traw`
/// shape is kept as text in whatever step is open (or a nameless one), an
/// unterminated `##[group]` is closed at the step boundary, and unknown `##[…]`
/// commands degrade to plain lines. Returns an empty log for empty input.
public func parseActionsLog(_ text: String) -> ActionsLog {
    guard !text.isEmpty else { return ActionsLog(sections: [], truncated: false) }

    var sections: [ActionsLogSection] = []
    var truncated = false
    var nextLineId = 0
    var nextGroupId = 0

    // Open step.
    var runId: String? = nil
    var job = ""
    var step = ""
    var groups: [ActionsLogGroup] = []
    // Open fold within the step, plus the loose lines before/after it.
    var groupTitle: String? = nil
    var groupLines: [ActionsLogLine] = []
    var looseLines: [ActionsLogLine] = []
    var started = false

    /// Close the open fold (if any) into `groups`.
    func flushGroup() {
        if let title = groupTitle {
            groups.append(ActionsLogGroup(id: nextGroupId, title: title,
                                          foldable: true, lines: groupLines))
            nextGroupId += 1
            groupTitle = nil
            groupLines = []
        } else if !looseLines.isEmpty {
            groups.append(ActionsLogGroup(id: nextGroupId, title: "",
                                          foldable: false, lines: looseLines))
            nextGroupId += 1
            looseLines = []
        }
    }

    /// Close the open step into `sections`.
    func flushSection() {
        flushGroup()
        guard started, !groups.isEmpty else {
            groups = []
            started = false
            return
        }
        sections.append(ActionsLogSection(id: sections.count, runId: runId,
                                          job: job, step: step, groups: groups))
        groups = []
        started = false
    }

    func append(_ line: ActionsLogLine) {
        started = true
        if groupTitle != nil { groupLines.append(line) } else { looseLines.append(line) }
    }

    for raw in text.components(separatedBy: "\n") {
        if raw.hasPrefix(runBannerPrefix) {
            flushSection()
            runId = runIdFromBanner(raw)
            job = ""; step = ""
            continue
        }
        if raw.hasPrefix("…(truncated)") || raw.hasPrefix("...(truncated)") {
            truncated = true
            continue
        }
        if raw.isEmpty { continue }

        let (lineJob, lineStep, rest) = splitGhLogLine(raw)
        // gh restates the job/step on every line, so a change means a new step.
        if let lineJob, let lineStep, lineJob != job || lineStep != step {
            flushSection()
            job = lineJob
            step = lineStep
        }

        let (timestamp, afterStamp) = splitTimestamp(rest)
        let (command, payload) = splitLogCommand(afterStamp)

        switch command {
        case "group":
            flushGroup()
            groupTitle = stripAnsi(payload)
            started = true
        case "endgroup":
            flushGroup()
        default:
            append(ActionsLogLine(id: nextLineId, severity: severity(for: command),
                                  timestamp: timestamp, spans: ansiSpans(payload)))
            nextLineId += 1
        }
    }
    flushSection()
    return ActionsLog(sections: sections, truncated: truncated)
}

/// `===== run 123 (failed steps) =====` → "123"; nil when the id isn't there.
private func runIdFromBanner(_ line: String) -> String? {
    let rest = line.dropFirst(runBannerPrefix.count)
    let id = rest.prefix { $0.isNumber }
    return id.isEmpty ? nil : String(id)
}

/// Split gh's `<job>\t<step>\t<raw line>` prefix off a line. Job/step are nil when
/// the line doesn't carry them (a wrapped line, or plain `gh run view --log` text
/// piped in), in which case the whole line is the content.
private func splitGhLogLine(_ raw: String) -> (job: String?, step: String?, rest: String) {
    let parts = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return (nil, nil, raw) }
    return (String(parts[0]), String(parts[1]), String(parts[2]))
}

/// Peel a leading RFC3339 timestamp (`2026-07-29T09:41:02.1234567Z `) off a log
/// line, returning it parsed plus the remaining text. Actions writes 7 fractional
/// digits, which `ISO8601DateFormatter` rejects, so the fraction is trimmed to 3.
/// The first line of a downloaded log carries a UTF-8 BOM ahead of the timestamp;
/// it is dropped rather than left to poison the parse.
private func splitTimestamp(_ untrimmed: String) -> (Date?, String) {
    let line = untrimmed.hasPrefix("\u{FEFF}") ? String(untrimmed.dropFirst()) : untrimmed
    guard let space = line.firstIndex(of: " ") else { return (nil, line) }
    let head = String(line[line.startIndex..<space])
    guard head.count >= 20, head.hasSuffix("Z"), head.contains("T"),
          let first = head.first, first.isNumber else { return (nil, line) }
    let rest = String(line[line.index(after: space)...])
    return (parseActionsTimestamp(head), rest)
}

/// Parse one Actions timestamp, trimming any fractional part beyond milliseconds.
func parseActionsTimestamp(_ stamp: String) -> Date? {
    var normalized = stamp
    if let dot = stamp.firstIndex(of: "."), stamp.hasSuffix("Z") {
        let fracStart = stamp.index(after: dot)
        let frac = stamp[fracStart..<stamp.index(before: stamp.endIndex)]
        normalized = String(stamp[stamp.startIndex..<fracStart]) + frac.prefix(3) + "Z"
    }
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: normalized) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: normalized)
}

/// Peel an Actions log command off a line: the `##[group]title` form the log
/// stream uses, and the `::error file=a.swift,line=2::message` workflow-command
/// form that also shows up. Returns the lower-cased command (empty for a plain
/// line) and the payload after it.
private func splitLogCommand(_ line: String) -> (command: String, payload: String) {
    if line.hasPrefix("##["), let close = line.firstIndex(of: "]") {
        let name = line[line.index(line.startIndex, offsetBy: 3)..<close]
        return (name.lowercased(), String(line[line.index(after: close)...]))
    }
    if line.hasPrefix("::") {
        let afterMarker = line.dropFirst(2)
        // `name` runs to the first space (parameters follow) or the closing `::`.
        guard let close = afterMarker.range(of: "::") else { return ("", line) }
        let head = afterMarker[afterMarker.startIndex..<close.lowerBound]
        let name = head.prefix { $0 != " " }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return ("", line) }
        return (name.lowercased(), String(afterMarker[close.upperBound...]))
    }
    return ("", line)
}

/// Map an Actions log command to how loudly the line should read. Unknown commands
/// (`set-output`, `add-mask`, …) are noise, not content — they read as `command`.
private func severity(for command: String) -> ActionsLogSeverity {
    switch command {
    case "": return .plain
    case "error": return .error
    case "warning": return .warning
    case "notice", "section": return .notice
    case "debug": return .debug
    default: return .command
    }
}

// MARK: - ANSI

/// Strip every ANSI escape sequence from a string.
func stripAnsi(_ s: String) -> String {
    ansiSpans(s).map(\.text).joined()
}

/// Split a line on its ANSI SGR escapes into attributed spans. Only foreground
/// colour and bold are carried — the two things Actions logs actually use to mean
/// something; other attributes (and non-SGR sequences like cursor moves) are
/// dropped along with the escape. Codes we don't understand reset to default
/// rather than leaking into the rest of the line.
func ansiSpans(_ s: String) -> [ActionsLogSpan] {
    guard s.contains("\u{1B}") else {
        return s.isEmpty ? [] : [ActionsLogSpan(text: s)]
    }
    var spans: [ActionsLogSpan] = []
    var buffer = ""
    var fg: Int? = nil
    var bold = false

    func flush() {
        guard !buffer.isEmpty else { return }
        spans.append(ActionsLogSpan(text: buffer, fg: fg, bold: bold))
        buffer = ""
    }

    var i = s.startIndex
    while i < s.endIndex {
        guard s[i] == "\u{1B}", s.index(after: i) < s.endIndex,
              s[s.index(after: i)] == "[" else {
            buffer.append(s[i])
            i = s.index(after: i)
            continue
        }
        // CSI … final-byte. Scan to the first byte in @–~, which ends the sequence.
        var j = s.index(i, offsetBy: 2)
        var params = ""
        while j < s.endIndex, !("\u{40}"..."\u{7E}").contains(s[j]) {
            params.append(s[j])
            j = s.index(after: j)
        }
        guard j < s.endIndex else { break } // truncated escape — drop the tail
        let final = s[j]
        if final == "m" {
            flush()
            applySgr(params, fg: &fg, bold: &bold)
        }
        i = s.index(after: j)
    }
    flush()
    return spans
}

/// Apply one SGR parameter list to the running attributes.
private func applySgr(_ params: String, fg: inout Int?, bold: inout Bool) {
    let codes = params.split(separator: ";", omittingEmptySubsequences: false)
    // A bare `ESC[m` is a reset.
    if codes.isEmpty || params.isEmpty {
        fg = nil; bold = false
        return
    }
    var idx = codes.startIndex
    while idx < codes.endIndex {
        let code = Int(codes[idx]) ?? 0
        switch code {
        case 0: fg = nil; bold = false
        case 1: bold = true
        case 22: bold = false
        case 30...37, 90...97: fg = code
        case 39: fg = nil
        case 38, 48:
            // Extended colour: `38;5;n` / `38;2;r;g;b` (and the 48 background
            // equivalents). Fall back to the default colour and step over the
            // arguments, so a `5` or a `31` inside them isn't read as an attribute.
            if code == 38 { fg = nil }
            let next = codes.index(after: idx)
            let mode = next < codes.endIndex ? Int(codes[next]) ?? 0 : 0
            let consumed = mode == 2 ? 5 : (mode == 5 ? 3 : 1)
            idx = codes.index(idx, offsetBy: consumed, limitedBy: codes.endIndex) ?? codes.endIndex
            continue
        default: break // background, italics, underline… nothing to carry
        }
        idx = codes.index(after: idx)
    }
}
