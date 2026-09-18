import Foundation

/// What a wait blocks on.
///
/// Both conditions are defined on things a caller can reason about without
/// knowing which CLI is running: the rendered grid, and pty silence. Neither
/// touches the provider heuristic (`ActivityDetector`) — "quiet" here means no
/// pty output for the window, nothing more.
public enum SessionWaitCondition: Sendable, Equatable {
    /// The session's screen shows this text.
    case text(String)
    /// No pty output for this many milliseconds. A session that has not produced a
    /// byte since it was created counts as quiet from its creation — a CLI still
    /// being exec'd has genuinely said nothing, and the caller asked about silence.
    case idle(ms: Int)
}

/// How a wait ended. Four distinct cases so a caller can branch without matching
/// on a message string.
public enum SessionWaitOutcome: String, Sendable, Codable, Equatable {
    /// The condition held.
    case matched
    /// The timeout elapsed with the condition never holding.
    case timedOut = "timed_out"
    /// No session with that id exists at all.
    case sessionGone = "session_gone"
    /// The session exists but its process is not running — it exited (or was put
    /// to sleep) before the condition held.
    case sessionExited = "session_exited"
}

/// The live state a wait samples, as plain closures rather than a `Session`
/// reference, so the engine is drivable from a test without a pty.
public struct SessionWaitProbe: Sendable {
    public var isRunning: @Sendable () -> Bool
    /// Wall-clock ms of the last byte the pty produced.
    public var lastOutputMs: @Sendable () -> Int
    /// The visible grid, as the model parsed it.
    public var screen: @Sendable () -> TerminalSnapshot
    /// How many scrollback history rows the model retains right now.
    public var scrollbackRows: @Sendable () -> Int
    /// The last n scrollback history rows, oldest first.
    public var scrollbackTail: @Sendable (Int) -> [TerminalRow]

    public init(
        isRunning: @escaping @Sendable () -> Bool,
        lastOutputMs: @escaping @Sendable () -> Int,
        screen: @escaping @Sendable () -> TerminalSnapshot,
        scrollbackRows: @escaping @Sendable () -> Int = { 0 },
        scrollbackTail: @escaping @Sendable (Int) -> [TerminalRow] = { _ in [] }
    ) {
        self.isRunning = isRunning
        self.lastOutputMs = lastOutputMs
        self.screen = screen
        self.scrollbackRows = scrollbackRows
        self.scrollbackTail = scrollbackTail
    }
}

/// A parsed wait request: a condition plus the bound on how long to block.
public struct SessionWaitRequest: Sendable, Equatable {
    public var condition: SessionWaitCondition
    public var timeoutMs: Int

    public init(condition: SessionWaitCondition, timeoutMs: Int) {
        self.condition = condition
        self.timeoutMs = timeoutMs
    }
}

/// Block until a session's screen shows some text, or its output goes quiet.
///
/// The point is to replace sleep-and-poll in everything scripted against a
/// session (the oracle sidecar, dispatch, Telegram steering): a caller states the
/// condition once and is told which of four things happened.
public enum SessionWait {
    /// How often the condition is re-evaluated. Text is read off the parsed grid,
    /// which is cheap; 50ms is well under the frame cadence of any TUI we host.
    public static let pollMs = 50
    public static let defaultTimeoutMs = 30_000
    /// One day — the longest duration the CLI grammar spells (`1d`).
    public static let maxTimeoutMs = 24 * 60 * 60 * 1000
    /// Ceiling on how much history one poll re-reads when a burst scrolled many
    /// rows off the screen between two polls.
    public static let maxCatchUpRows = 512

    /// Run the wait to one of the four outcomes.
    ///
    /// Cancellation (the HTTP client hung up) ends the wait as `timedOut`: nobody
    /// is left to read the answer, and `Nap` swallows cancellation, so a loop that
    /// didn't check would spin hot for the rest of the timeout.
    public static func run(
        condition: SessionWaitCondition,
        timeoutMs: Int,
        probe: SessionWaitProbe,
        pollMs: Int = SessionWait.pollMs
    ) async -> SessionWaitOutcome {
        let deadline = nowMs() + max(0, timeoutMs)
        // Where scrollback stood when the wait began: only rows that arrive after
        // that are worth re-reading, so a quiet session costs nothing per poll.
        var seenScrollbackRows = probe.scrollbackRows()
        while true {
            if holds(condition, probe, &seenScrollbackRows) { return .matched }
            if !probe.isRunning() { return .sessionExited }
            if Task.isCancelled { return .timedOut }
            let remaining = deadline - nowMs()
            if remaining <= 0 { return .timedOut }
            await Nap.ms(min(pollMs, remaining))
        }
    }

    private static func holds(
        _ condition: SessionWaitCondition,
        _ probe: SessionWaitProbe,
        _ seenScrollbackRows: inout Int
    ) -> Bool {
        switch condition {
        case .idle(let ms):
            return nowMs() - probe.lastOutputMs() >= max(0, ms)
        case .text(let needle):
            guard !needle.isEmpty else { return false }
            let screen = probe.screen()
            var rows = catchUpRows(probe, &seenScrollbackRows, visibleRows: screen.rows)
            rows.append(contentsOf: screen.lines)
            return SessionWaitScreen.rows(rows, cols: screen.cols, contain: needle)
        }
    }

    /// History rows to search alongside the visible screen: what scrolled off since
    /// the last poll, so a line that appeared and scrolled away inside one poll
    /// interval still matches. Always at least a screenful, because a model whose
    /// scrollback cap is already full stops reporting growth while lines keep
    /// scrolling through it.
    private static func catchUpRows(
        _ probe: SessionWaitProbe,
        _ seenScrollbackRows: inout Int,
        visibleRows: Int
    ) -> [TerminalRow] {
        let total = probe.scrollbackRows()
        let grew = max(0, total - seenScrollbackRows)
        seenScrollbackRows = total
        let count = min(max(grew, visibleRows), maxCatchUpRows)
        guard count > 0, total > 0 else { return [] }
        return probe.scrollbackTail(count)
    }
}

/// Text matching over parsed grid rows — the "what a human would see" side of the
/// primitive. Defined on rows rather than on the raw byte stream, so no escape
/// sequence can split a match and no scrollback re-parse at the wrong width can
/// garble one.
public enum SessionWaitScreen {
    /// Does `needle` appear on these rows?
    ///
    /// Two readings of the grid count, because both are things a human sees:
    /// - rows as separate lines (joined by "\n"), so a needle with newlines works;
    /// - rows flowed back together at full width, so a line the terminal WRAPPED
    ///   across two rows still matches. Padding each row back out to `cols` is what
    ///   keeps that from also joining two visually separate short lines: a wrapped
    ///   row fills the width and butts against the next one, a short row doesn't.
    public static func rows(_ rows: [TerminalRow], cols: Int, contain needle: String) -> Bool {
        guard !needle.isEmpty, !rows.isEmpty else { return false }
        if rows.contains(where: { $0.text.contains(needle) }) { return true }
        if rows.map(\.text).joined(separator: "\n").contains(needle) { return true }
        return flowed(rows, cols: cols).contains(needle)
    }

    /// The rows padded back to full width and concatenated with no separator.
    static func flowed(_ rows: [TerminalRow], cols: Int) -> String {
        var out = ""
        for row in rows {
            var width = 0
            for cell in row.cells {
                out.append(cell.char)
                width += max(1, cell.width)
            }
            if width < cols { out.append(String(repeating: " ", count: cols - width)) }
        }
        return out
    }
}

/// The duration grammar the wait takes on the wire: `500ms`, `2s`, `1m`, `4h`,
/// `1d`. A bare number is milliseconds.
public enum WaitDuration {
    public static func ms(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        let units: [(String, Double)] = [("ms", 1), ("s", 1000), ("m", 60_000), ("h", 3_600_000), ("d", 86_400_000)]
        for (suffix, scale) in units where s.hasSuffix(suffix) {
            let value = String(s.dropLast(suffix.count))
            guard let n = number(value), n >= 0 else { return nil }
            return Int((n * scale).rounded())
        }
        guard let n = number(s), n >= 0 else { return nil }
        return Int(n.rounded())
    }

    /// A plain decimal number — no exponent, no sign, no thousands separators, so
    /// `2e3s` or `-1s` is a parse failure rather than a surprising duration.
    private static func number(_ s: String) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), s.filter({ $0 == "." }).count <= 1 else {
            return nil
        }
        return Double(s)
    }
}

/// Why a wait request was rejected — one line, already phrased for the caller.
public struct SessionWaitBadRequest: Error, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Validation of the wire fields, separate from the HTTP route so the rules are
/// testable and the route stays a few lines.
public enum SessionWaitParse {
    /// Build a request from the body fields, or return the one-line reason it is
    /// a bad request. `idle`/`timeout` are the string duration spellings of
    /// `idleMs`/`timeoutMs`.
    public static func request(
        text: String?,
        idleMs: Int?,
        idle: String?,
        timeoutMs: Int?,
        timeout: String?
    ) -> Result<SessionWaitRequest, SessionWaitBadRequest> {
        let wantsText = !(text ?? "").isEmpty
        let idleWindow: Int?
        switch duration(idleMs, idle, field: "idle") {
        case .failure(let reason): return .failure(reason)
        case .success(let ms): idleWindow = ms
        }
        guard wantsText || idleWindow != nil else {
            return .failure(SessionWaitBadRequest("text or idleMs required"))
        }
        guard !(wantsText && idleWindow != nil) else {
            return .failure(SessionWaitBadRequest("text and idleMs are mutually exclusive"))
        }
        if let idleWindow, idleWindow < 0 { return .failure(SessionWaitBadRequest("idleMs must not be negative")) }

        var bound = SessionWait.defaultTimeoutMs
        switch duration(timeoutMs, timeout, field: "timeout") {
        case .failure(let reason): return .failure(reason)
        case .success(let ms):
            if let ms {
                guard ms > 0 else { return .failure(SessionWaitBadRequest("timeoutMs must be positive")) }
                bound = min(ms, SessionWait.maxTimeoutMs)
            }
        }
        let condition: SessionWaitCondition = wantsText ? .text(text!) : .idle(ms: idleWindow!)
        return .success(SessionWaitRequest(condition: condition, timeoutMs: bound))
    }

    /// One duration from either spelling; the numeric field wins when both are set.
    private static func duration(_ ms: Int?, _ spelled: String?, field: String) -> Result<Int?, SessionWaitBadRequest> {
        if let ms { return .success(ms) }
        guard let spelled, !spelled.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(nil) }
        guard let parsed = WaitDuration.ms(spelled) else {
            return .failure(SessionWaitBadRequest(
                "could not read \(field) '\(spelled)' — use 500ms, 2s, 1m, 4h or 1d"))
        }
        return .success(parsed)
    }
}

public extension Session {
    /// This session as a wait target. Holds the session for the life of the wait,
    /// which is bounded by the request's timeout.
    var waitProbe: SessionWaitProbe {
        SessionWaitProbe(
            isRunning: { self.isRunning },
            lastOutputMs: { self.lastOutputMs },
            screen: { self.terminalModel.snapshot() },
            scrollbackRows: { self.terminalModel.scrollbackRows },
            scrollbackTail: { self.terminalModel.styledScrollbackTail($0) })
    }
}
