import Foundation

/// Infers whether a session is working, finished a turn, or waiting for the user
/// from the raw pty byte stream alone (mirrors `apps/server/src/activityDetector.ts`).
///
/// The stream is fed into a headless `TerminalScreen`, so the detector reads the
/// *actual rendered screen* rather than a flattened byte tail. Both `claude` and
/// `codex` paint an "esc to interrupt" footer once at the start of a turn and then
/// only animate the timer digits via cursor moves — the phrase is never re-emitted.
/// A concatenated tail therefore can't tell whether the footer is still on screen,
/// which is the whole question; the grid can, because the footer occupies real
/// cells until the CLI erases them at turn end. So:
///
/// - **busy** while the working footer is visible in the current frame.
/// - on a brief quiet period we re-read the screen: footer gone + a prompt/option
///   menu visible => **waitingInput**; footer gone + nothing => **idle**.
/// - a longer watchdog demotes a stuck **busy** if the footer somehow lingers but
///   the spinner has stopped emitting (the timer repaints ~1/s while truly busy,
///   so prolonged total silence means the turn really ended).
///
/// Busy can only be *entered* via the footer phrase, so the startup banner and
/// keystroke echoes never trigger it. Best-effort; a CLI wording change can defeat
/// the footer/prompt patterns.
///
/// Thread-safety: all work happens on a private serial queue. `feed` dispatches
/// onto it; the timers fire on it; `onChange` is invoked on it. Callers hop to the
/// main thread themselves if needed.
public final class ActivityDetector: @unchecked Sendable {
    public typealias ChangeListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void

    /// Quiet period after output stops before we re-classify the screen.
    private let settleMs: Int
    /// Longer silence after which a still-"busy" footer is treated as stale (the
    /// spinner repaints while truly working, so this much silence means done).
    private let watchdogMs: Int

    private let queue: DispatchQueue
    private let onChange: ChangeListener
    private let screen: TerminalScreen
    private var state: SessionActivity = .idle
    private var generation = 0

    public init(
        cols: Int = 120,
        rows: Int = 40,
        settleMs: Int = 250,
        watchdogMs: Int = 8000,
        queue: DispatchQueue = DispatchQueue(label: "juancode.activity"),
        onChange: @escaping ChangeListener
    ) {
        self.settleMs = settleMs
        self.watchdogMs = watchdogMs
        self.queue = queue
        self.onChange = onChange
        self.screen = TerminalScreen(cols: cols, rows: rows)
    }

    public var activity: SessionActivity {
        queue.sync { state }
    }

    /// A point-in-time snapshot of the whole rendered screen, taken on the detector's
    /// queue so it's consistent with the byte stream fed so far. Used by
    /// `Session.autoSubmit` to detect when the TUI has settled (stable frames).
    public func screenSnapshot() -> String {
        queue.sync { screen.visibleText }
    }

    /// The bottom `rows` of the rendered screen — the footer / input-box region —
    /// so `Session.autoSubmit` can confirm a seeded prompt landed in (or left) the
    /// input box without matching the same text echoed up in the conversation.
    public func inputRegionSnapshot(rows: Int) -> String {
        queue.sync { screen.bottomText(rows) }
    }

    /// Feed a chunk of raw pty output.
    public func feed(_ data: String) {
        queue.async { self._feed(data) }
    }

    /// Keep the screen model in step with the pty size so cursor/erase math stays
    /// accurate. Called from `Session.resize`.
    public func resize(cols: Int, rows: Int) {
        queue.async { self.screen.resize(cols: cols, rows: rows) }
    }

    /// The session ended — cancel any pending timers and return to idle.
    public func reset() {
        queue.async {
            self.generation += 1
            self.transition(.idle, notify: false)
        }
    }

    // MARK: - internals (always on `queue`)

    private func _feed(_ data: String) {
        // The screen must see every byte to stay an accurate mirror.
        screen.feed(data)
        if state == .busy {
            // Already working: any output (re)starts the settle/watchdog clocks.
            armTimers()
        } else if data.range(of: "interrupt", options: .caseInsensitive) != nil {
            // Cheap gate: only a frame that could carry the working footer is worth
            // re-reading the screen for. If the footer is now visible we go busy.
            if Self.workingRe.firstMatch(in: normalizedScreen()) {
                transition(.busy, notify: false)
                armTimers()
            }
        }
        // Idle with no possible footer: nothing to do (don't reclassify idle output
        // into waitingInput — active states are only entered via a working turn).
    }

    /// (Re)arm both the short settle timer and the long stuck-busy watchdog. The
    /// generation guard cancels stale timers when newer output arrives.
    private func armTimers() {
        generation += 1
        let gen = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settle(demoteStaleFooter: false)
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(watchdogMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settle(demoteStaleFooter: true)
        }
    }

    /// Re-read the screen and classify. Only meaningful while busy: it ends a turn.
    /// `demoteStaleFooter` (the watchdog path) ignores a lingering footer and
    /// settles anyway, so we never hang on busy after the spinner has gone silent.
    private func settle(demoteStaleFooter: Bool) {
        guard state == .busy else { return }
        let text = normalizedScreen()
        let next: SessionActivity
        if !demoteStaleFooter, Self.workingRe.firstMatch(in: text) {
            next = .busy // still working — leave it
        } else {
            next = Self.promptRes.contains { $0.firstMatch(in: text) } ? .waitingInput : .idle
        }
        // We're leaving busy on a real turn boundary, so notify.
        transition(next, notify: next != .busy)
    }

    private func transition(_ next: SessionActivity, notify: Bool) {
        if next == state { return }
        state = next
        onChange(next, notify)
    }

    /// The visible screen with runs of intra-line whitespace collapsed to a single
    /// space. The grid renders cursor-positioned footer segments as the *actual*
    /// column gap (many spaces); collapsing restores a compact line so the
    /// distance-bounded `workingRe` (`[^\n]{0,40}`) matches as intended.
    private func normalizedScreen() -> String {
        Self.wsRe.replacingMatches(in: screen.visibleText, with: " ")
    }

    // MARK: - patterns (ICU translations of the TS regexes)

    /// The "esc to interrupt" working line, tolerant of wording.
    private static let workingRe = Regex(
        #"\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b"#, caseInsensitive: true)

    /// Runs of spaces/tabs within a line (not newlines), collapsed before matching.
    private static let wsRe = Regex(#"[^\S\n]{2,}"#, caseInsensitive: false)

    /// Markers that a settled screen is an interactive question awaiting a choice.
    private static let promptRes: [Regex] = [
        Regex(#"❯\s*\d+\.\s"#, caseInsensitive: false),
        Regex(#"\bDo you want to\b"#, caseInsensitive: true),
        Regex(#"\bProceed\?"#, caseInsensitive: true),
        Regex(#"\(y/n\)"#, caseInsensitive: true),
        Regex(#"\[y/n\]"#, caseInsensitive: true),
        Regex(#"\bAllow\b[^\n]{0,40}\?"#, caseInsensitive: true),
    ]
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
