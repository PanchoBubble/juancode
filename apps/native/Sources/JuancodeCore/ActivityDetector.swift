import Foundation

/// Infers whether a session is working, finished a turn, or waiting for the user
/// from the raw pty byte stream alone (mirrors `apps/server/src/activityDetector.ts`).
///
/// Both `claude` and `codex` paint an "esc to interrupt" status line *once* when a
/// turn starts, then only update the changing bits via cursor moves. We use that
/// phrase only to *enter* `busy`; from there any continued output keeps it busy,
/// and we settle once output goes quiet for `settleMs`. Because busy can only be
/// entered via the phrase, the startup banner and keystroke echoes never trigger
/// it. On settle we classify the final screen: an option menu / yes-no prompt =>
/// `waitingInput`, else `idle`. Best-effort; a CLI wording change can defeat it.
///
/// Thread-safety: all work happens on a private serial queue. `feed` dispatches
/// onto it; the settle timer fires on it; `onChange` is invoked on it. Callers
/// hop to the main thread themselves if needed.
public final class ActivityDetector: @unchecked Sendable {
    public typealias ChangeListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void

    /// Grace period after the working indicator stops repainting before we settle.
    private let settleMs: Int
    /// How much of the (ANSI-stripped) recent screen we keep for classification.
    private static let tailLimit = 4000

    private let queue: DispatchQueue
    private let onChange: ChangeListener
    private var state: SessionActivity = .idle
    private var tail = ""
    private var settleGeneration = 0

    public init(
        settleMs: Int = 1200,
        queue: DispatchQueue = DispatchQueue(label: "juancode.activity"),
        onChange: @escaping ChangeListener
    ) {
        self.settleMs = settleMs
        self.queue = queue
        self.onChange = onChange
    }

    public var activity: SessionActivity {
        queue.sync { state }
    }

    /// Feed a chunk of raw pty output.
    public func feed(_ data: String) {
        queue.async { self._feed(data) }
    }

    /// The session ended — clear any pending settle and return to idle.
    public func reset() {
        queue.async {
            self.settleGeneration += 1
            self.transition(.idle, notify: false)
        }
    }

    // MARK: - internals (always on `queue`)

    private func _feed(_ data: String) {
        let stripped = Self.stripAnsi(data)
        if !stripped.isEmpty {
            let combined = tail + stripped
            tail = String(combined.suffix(Self.tailLimit))
        }
        // Matched against the current frame only (not the historical tail) so it
        // genuinely marks the *start* of a turn.
        if Self.workingRe.firstMatch(in: stripped) {
            markBusy()
        } else if state == .busy {
            armSettle()
        }
    }

    private func markBusy() {
        transition(.busy, notify: false)
        armSettle()
    }

    private func armSettle() {
        settleGeneration += 1
        let gen = settleGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
            guard let self, gen == self.settleGeneration else { return }
            self.settle()
        }
    }

    private func settle() {
        let recent = String(tail.suffix(2000))
        let next: SessionActivity = Self.promptRes.contains { $0.firstMatch(in: recent) }
            ? .waitingInput
            : .idle
        // A settle always follows a busy period, so this is a real turn boundary:
        // notify even when classifying back to idle.
        transition(next, notify: true)
    }

    private func transition(_ next: SessionActivity, notify: Bool) {
        if next == state { return }
        state = next
        onChange(next, notify)
    }

    // MARK: - patterns (ICU translations of the TS regexes)
    //
    // ICU `\x{..}` hex escapes pass through Swift raw strings untouched and ICU
    // interprets them, so we never embed literal control bytes. ESC=1B, BEL=07.

    /// The "esc to interrupt" working line, tolerant of wording.
    private static let workingRe = Regex(
        #"\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b"#, caseInsensitive: true)

    /// CSI/OSC escape sequences + lone control bytes, stripped before matching.
    private static let ansiRe = Regex(
        #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}[\]P][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?|\x{1B}[()][AB0-2]|\x{1B}[=>]|[\x{00}-\x{08}\x{0B}\x{0C}\x{0E}-\x{1F}]"#,
        caseInsensitive: false
    )

    /// Markers that a settled screen is an interactive question awaiting a choice.
    private static let promptRes: [Regex] = [
        Regex(#"❯\s*\d+\.\s"#, caseInsensitive: false),
        Regex(#"\bDo you want to\b"#, caseInsensitive: true),
        Regex(#"\bProceed\?"#, caseInsensitive: true),
        Regex(#"\(y/n\)"#, caseInsensitive: true),
        Regex(#"\[y/n\]"#, caseInsensitive: true),
        Regex(#"\bAllow\b[^\n]{0,40}\?"#, caseInsensitive: true),
    ]

    static func stripAnsi(_ s: String) -> String {
        ansiRe.replacingMatches(in: s, with: "")
    }
}

/// Thin NSRegularExpression wrapper so the patterns above read cleanly.
///
/// `@unchecked Sendable`: the sole stored property `re` is an immutable `let`
/// `NSRegularExpression`, which Apple documents as thread-safe for concurrent
/// matching. There is no mutable state, so sharing instances across threads is
/// safe.
struct Regex: @unchecked Sendable {
    private let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool) {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        // Patterns are compile-time constants; a bad one is a programmer error.
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }
    func firstMatch(in s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }
    func replacingMatches(in s: String, with template: String) -> String {
        guard !s.isEmpty else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
