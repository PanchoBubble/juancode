import Foundation

/// Structured-event kinds the CLI writes to its append-only stream-json transcript.
/// A `user` record is the user's own prompt landing (a turn boundary, but not the
/// agent working), so it is excluded from {@link batchHasAgentActivity}; the
/// agent's first `assistant` / `thinking` / `toolUse` / `toolResult` record that
/// follows is the busy pulse. Mirrors the kinds in `apps/server/src/protocol.ts`.
public enum StructuredEventKind: String, Sendable {
    case user
    case assistant
    case thinking
    case toolUse = "tool_use"
    case toolResult = "tool_result"
}

private let agentEventKinds: Set<StructuredEventKind> = [
    .assistant, .thinking, .toolUse, .toolResult,
]

/// True when a batch of normalized transcript kinds carries an agent-produced record.
public func batchHasAgentActivity(_ kinds: [StructuredEventKind]) -> Bool {
    kinds.contains { agentEventKinds.contains($0) }
}

/// One normalized transcript batch: the event kinds plus which `tool_use` ids the
/// batch opened and which it resolved (a `tool_result` record carries its
/// `tool_use_id`). The ids let the detector know a call is still in flight — a
/// delegated subagent is one open `tool_use` for its whole lifetime — so a long
/// silent stretch between `tool_use` and `tool_result` never reads as idle.
public struct StructuredEventBatch: Sendable {
    public var kinds: [StructuredEventKind]
    public var openedToolUseIds: [String]
    public var resolvedToolUseIds: [String]

    public init(
        kinds: [StructuredEventKind],
        openedToolUseIds: [String] = [],
        resolvedToolUseIds: [String] = []
    ) {
        self.kinds = kinds
        self.openedToolUseIds = openedToolUseIds
        self.resolvedToolUseIds = resolvedToolUseIds
    }
}

/// Infers whether an agent session is working, finished a turn, or is waiting for
/// the user, fusing two signals (mirrors `apps/server/src/activityDetector.ts`):
///
/// 1. **Structured stream** (preferred). The CLIs write an append-only stream-json
///    transcript as they run; new records appear *only* while the agent is actively
///    producing a turn. `Session` tails that transcript and calls `feedStructured`
///    with each batch of normalized kinds. A batch carrying an agent-produced kind
///    is a wording-independent "the agent is working" pulse — robust to CLI footer
///    copy changes. `structuredTurn` then lets settle classify on the screen's
///    prompt/quiet state instead of waiting for the footer to be erased. Batches
///    also carry `tool_use` ids: while one is unresolved the turn is held busy —
///    a slow tool or delegated subagent goes transcript- *and* screen-quiet for
///    minutes, which must not read as idle.
///
/// 2. **Rendered PTY screen** (fallback). The detector reads the *actual rendered
///    screen* from the session's headless `SessionTerminalModel` — the single VT
///    parse on the session workQueue (juancode-a2h) — instead of running its own
///    emulator over the byte stream. Both `claude` and `codex` paint an "esc to
///    interrupt" footer while a turn runs and an option-menu / yes-no prompt when
///    they pause. This drives **busy** when no transcript is available yet, and
///    distinguishes **waitingInput** from **idle** at turn end (a permission prompt
///    isn't written to the transcript until answered).
///
/// Busy is only ever *entered* via the footer phrase or a structured agent event, so
/// the startup banner and keystroke echoes never trigger it. A prompt can also appear
/// *without* a preceding turn — a startup folder-trust dialog, an auth prompt, or a
/// resumed session re-rendering its pending permission menu — so the screen path also
/// promotes **idle → waitingInput** when a prompt marker settles into the bottom
/// region (juancode-8w5), and demotes back to idle once it is answered away.
///
/// Thread-safety: all work happens on a private serial queue. `feed` /
/// `feedStructured` dispatch onto it; the timers fire on it; `onChange` is invoked on
/// it. Callers hop to the main thread themselves if needed.
public final class ActivityDetector: @unchecked Sendable {
    public typealias ChangeListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void

    /// Quiet period after output stops before we re-classify the screen.
    private let settleMs: Int
    /// Longer silence after which a still-"busy" footer is treated as stale (the
    /// spinner repaints while truly working, so this much silence means done).
    private let watchdogMs: Int
    /// Ceiling on how long an unresolved `tool_use` may hold busy, measured from the
    /// last structured pulse. A crashed tool never writes its `tool_result`, so past
    /// the cap the hold is released and settle classifies normally.
    private let toolHoldCapMs: Int

    private let queue: DispatchQueue
    private let onChange: ChangeListener
    /// Fired when the stuck-busy watchdog (not the ordinary settle) is what ends a
    /// busy turn — the footer went silent past `watchdogMs`. A diagnostics hook
    /// (the session logs it); nil by default.
    private let onWatchdogSettle: (@Sendable () -> Void)?
    /// The rendered screen the classifier reads. In production this is the
    /// session's shared `SessionTerminalModel`, fed once in `Session.handleData`
    /// *before* the detector sees the chunk; in the byte-fed mode (tests) the
    /// detector owns a private model and feeds it itself.
    private let screen: SessionTerminalModel
    /// Whether `screen` is the detector's own (byte-fed mode) — only then do
    /// `feed`/`resize` drive it; a shared model is owned by the session.
    private let ownsScreen: Bool
    private var state: SessionActivity = .idle
    private var generation = 0
    /// Whether the *current* busy turn was started by a structured agent event.
    /// When true, settle classifies on the screen's prompt/quiet state instead of
    /// keeping the turn busy on a footer the CLI hasn't repainted yet. Reset on leave.
    private var structuredTurn = false
    /// Label of the last `PromptPattern` that matched, for debugging which shape
    /// tripped a `waitingInput` classification.
    private var lastMatchedPrompt: String?
    /// `tool_use` ids the transcript has opened but not yet resolved. While any is
    /// pending, settle refuses to leave busy (a slow tool / delegated subagent goes
    /// transcript- and screen-quiet for minutes) — a visible prompt still wins, since
    /// the tool may be waiting on permission. Cleared on any leave-busy and capped by
    /// `toolHoldCapMs` so a crashed tool can't pin busy forever.
    private var pendingToolUseIds: Set<String> = []
    /// When the last structured agent pulse arrived; anchors the `toolHoldCapMs` cap.
    private var lastStructuredAt = Date.distantPast
    /// Trailing bytes of a multibyte UTF-8 sequence split across a `feed` boundary,
    /// carried into the next chunk so a split multibyte gate token (the "❯" menu
    /// cursor) still decodes intact for the cheap substring gates rather than as
    /// replacement characters. Touched only on `queue`. (juancode-5qw.6)
    private var pendingBytes: [UInt8] = []

    /// Byte-fed mode: the detector owns a private headless model and renders the
    /// stream itself. Kept for tests (the corpus feeds raw CLI bytes directly);
    /// production uses `init(observing:)` so the session's single parse is shared.
    public init(
        cols: Int = 120,
        rows: Int = 40,
        settleMs: Int = 250,
        watchdogMs: Int = 8000,
        toolHoldCapMs: Int = 30 * 60 * 1000,
        queue: DispatchQueue = DispatchQueue(label: "juancode.activity"),
        onWatchdogSettle: (@Sendable () -> Void)? = nil,
        onChange: @escaping ChangeListener
    ) {
        self.settleMs = settleMs
        self.watchdogMs = watchdogMs
        self.toolHoldCapMs = toolHoldCapMs
        self.queue = queue
        self.onWatchdogSettle = onWatchdogSettle
        self.onChange = onChange
        self.screen = SessionTerminalModel(cols: cols, rows: rows, scrollbackLines: 0)
        self.ownsScreen = true
    }

    /// Shared-model mode (production): classify off `model`, the session's headless
    /// VT engine that already parses every pty chunk once on the workQueue. The
    /// caller must feed `model` before feeding the detector, so the screen the
    /// settle logic re-reads always includes the chunk that armed it.
    public init(
        observing model: SessionTerminalModel,
        settleMs: Int = 250,
        watchdogMs: Int = 8000,
        toolHoldCapMs: Int = 30 * 60 * 1000,
        queue: DispatchQueue = DispatchQueue(label: "juancode.activity"),
        onWatchdogSettle: (@Sendable () -> Void)? = nil,
        onChange: @escaping ChangeListener
    ) {
        self.settleMs = settleMs
        self.watchdogMs = watchdogMs
        self.toolHoldCapMs = toolHoldCapMs
        self.queue = queue
        self.onWatchdogSettle = onWatchdogSettle
        self.onChange = onChange
        self.screen = model
        self.ownsScreen = false
    }

    public var activity: SessionActivity {
        queue.sync { state }
    }

    /// Which `PromptPattern` label last classified a screen as a prompt, for debugging.
    public var lastPromptMatch: String? {
        queue.sync { lastMatchedPrompt }
    }

    /// Feed a chunk of raw pty output as bytes — the hot path from `Session`.
    /// Decodes incrementally on the detector's queue, carrying an incomplete
    /// trailing UTF-8 sequence across the chunk boundary so a multibyte gate token
    /// (the "❯" menu cursor) split between two pty reads is never corrupted into
    /// replacement characters before the cheap substring gates see it. No `String`
    /// is allocated on the caller's (pty) thread (juancode-5qw.6).
    public func feed(_ bytes: [UInt8]) {
        queue.async { self._feedBytes(bytes) }
    }

    /// Feed a chunk of already-decoded output. Convenience for callers holding a
    /// `String` (tests); routes through the same incremental decoder, which is a
    /// no-op carry for a whole (always-complete) string.
    public func feed(_ data: String) {
        feed(Array(data.utf8))
    }

    /// Feed a batch of normalized structured events from the session's transcript
    /// tail (the preferred signal). A batch carrying an agent-produced kind is a
    /// wording-independent "the agent is working" pulse: it enters/keeps busy and
    /// (re)arms the settle/watchdog clocks exactly like footer output does. The
    /// batch's tool ids also update the pending set that holds busy across the long
    /// silence of an in-flight tool call.
    public func feedStructured(_ batch: StructuredEventBatch) {
        queue.async { self._feedStructured(batch) }
    }

    /// Kinds-only convenience for callers with no tool-id plumbing.
    public func feedStructured(_ kinds: [StructuredEventKind]) {
        feedStructured(StructuredEventBatch(kinds: kinds))
    }

    /// The session ended — cancel any pending timers and return to idle.
    public func reset() {
        queue.async {
            self.generation += 1
            self.structuredTurn = false
            self.pendingToolUseIds.removeAll()
            self.pendingBytes.removeAll()
            self.transition(.idle, notify: false)
        }
    }

    // MARK: - internals (always on `queue`)

    /// Incrementally decode `bytes`, prepending any carried tail from the previous
    /// chunk and holding back a still-incomplete trailing sequence for the next one,
    /// then feed the complete decoded prefix to `_feed`. Only a plausibly-incomplete
    /// multibyte tail is carried; malformed bytes stay in the prefix so
    /// `String(decoding:)` replaces them exactly as before. The decoded string only
    /// drives the cheap gates — the screen itself renders from raw bytes.
    private func _feedBytes(_ bytes: [UInt8]) {
        // In byte-fed mode the own screen must see every raw byte (SwiftTerm carries
        // partial escape/UTF-8 sequences itself); a shared model was already fed by
        // the session before this chunk was enqueued.
        if ownsScreen { screen.feed(bytes) }
        let combined: [UInt8]
        if pendingBytes.isEmpty {
            combined = bytes
        } else {
            combined = pendingBytes + bytes
            pendingBytes = []
        }
        let cut = Utf8Boundary.completePrefixLength(combined)
        if cut < combined.count { pendingBytes = Array(combined[cut...]) }
        guard cut > 0 else { return } // whole chunk is an incomplete tail — nothing to feed yet
        _feed(String(decoding: combined[0..<cut], as: UTF8.self))
    }

    private func _feed(_ data: String) {
        if state == .busy {
            // Already working: any output (re)starts the settle/watchdog clocks.
            armTimers()
            return
        }
        let lower = data.lowercased()
        if lower.contains("interrupt"), Self.workingRe.firstMatch(in: normalizedScreen()) {
            // Cheap gate: only a frame that could carry the working footer is worth
            // re-reading the screen for. If the footer is now visible we go busy.
            structuredTurn = false
            transition(.busy, notify: false)
            armTimers()
            return
        }
        // Idle/waiting: a prompt can appear with no preceding working turn — a startup
        // folder-trust dialog, an auth prompt, a resumed session's pending permission
        // menu (juancode-8w5). Gate on cheap markers, then re-read on settle. While
        // already waiting we re-check on *any* output, since the answer that clears the
        // menu carries no marker of its own.
        if state == .waitingInput || Self.promptGate.contains(where: { lower.contains($0) }) {
            armPromptTimer()
        }
    }

    private func _feedStructured(_ batch: StructuredEventBatch) {
        pendingToolUseIds.formUnion(batch.openedToolUseIds)
        pendingToolUseIds.subtract(batch.resolvedToolUseIds)
        guard batchHasAgentActivity(batch.kinds) else { return }
        lastStructuredAt = Date()
        // A structured pulse is authoritative for this turn, whether it starts the
        // turn or upgrades one the screen path already opened (so settle no longer
        // waits on the footer being erased).
        structuredTurn = true
        if state != .busy { transition(.busy, notify: false) }
        armTimers()
    }

    /// True while an unresolved `tool_use` should keep the turn busy. Past the cap
    /// the pending set is dropped (a crashed tool never writes its `tool_result`),
    /// so classification returns to normal.
    private func holdsOpenToolUse() -> Bool {
        guard !pendingToolUseIds.isEmpty else { return false }
        if Date().timeIntervalSince(lastStructuredAt) * 1000 >= Double(toolHoldCapMs) {
            pendingToolUseIds.removeAll()
            return false
        }
        return true
    }

    /// (Re)arm both the short settle timer and the long stuck-busy watchdog. The
    /// generation guard cancels stale timers (busy *or* prompt) when newer output arrives.
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

    /// (Re)arm the idle→waiting settle. Shares the generation counter with
    /// `armTimers`, so starting a busy turn cancels a pending prompt re-read and
    /// vice versa — the latest frame always wins (juancode-8w5).
    private func armPromptTimer() {
        generation += 1
        let gen = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settlePrompt()
        }
    }

    /// Re-read the screen and classify. Only meaningful while busy: it ends a turn.
    /// `demoteStaleFooter` (the watchdog path) ignores a lingering footer and
    /// settles anyway, so we never hang on busy after the spinner has gone silent.
    private func settle(demoteStaleFooter: Bool) {
        guard state == .busy else { return }
        if !demoteStaleFooter, !structuredTurn, Self.workingRe.firstMatch(in: normalizedScreen()) {
            return // still working (screen path) — leave it busy
        }
        if matchPrompt() != nil {
            // A visible prompt beats the open-tool hold: a tool_use is written to the
            // transcript *before* its permission menu is answered, and the user must
            // be pinged. Leaving busy drops the hold (see `transition`).
            if demoteStaleFooter { onWatchdogSettle?() }
            transition(.waitingInput, notify: true)
            return
        }
        if holdsOpenToolUse() {
            // A tool call (or delegated subagent) is still in flight — transcript and
            // screen both go quiet for minutes here, including past the watchdog.
            // Re-arm so the tool_result, a late prompt, or the cap ends the hold.
            armTimers()
            return
        }
        if demoteStaleFooter { onWatchdogSettle?() }
        // We're leaving busy on a real turn boundary, so notify.
        transition(.idle, notify: true)
    }

    /// Re-classify a non-busy screen: a prompt in the trusted region enters
    /// `waitingInput` (notify), and a prompt that has since cleared demotes a stale
    /// `waitingInput` back to idle. Never touches a busy turn (that's `settle`).
    private func settlePrompt() {
        guard state == .idle || state == .waitingInput else { return }
        if matchPrompt() != nil {
            if state != .waitingInput { transition(.waitingInput, notify: true) }
        } else if state == .waitingInput {
            // The prompt was answered / repainted away — back to idle (no ding).
            transition(.idle, notify: false)
        }
    }

    /// The label of the first `PromptPattern` visible on the settled screen, or nil.
    /// Full-screen markers (the selection cursor) are matched everywhere; prose-like
    /// markers only in the bottom region. Records the hit in `lastMatchedPrompt`.
    private func matchPrompt() -> String? {
        let full = normalizedScreen()
        let bottom = normalizedBottom()
        for p in Self.promptPatterns where p.re.firstMatch(in: p.bottomOnly ? bottom : full) {
            lastMatchedPrompt = p.label
            return p.label
        }
        lastMatchedPrompt = nil
        return nil
    }

    private func transition(_ next: SessionActivity, notify: Bool) {
        if next == state { return }
        state = next
        if next != .busy {
            structuredTurn = false
            // Any legitimate exit from busy abandons the open-tool hold; a tool that
            // is still running re-enters busy through its own output/records.
            pendingToolUseIds.removeAll()
        }
        onChange(next, notify)
    }

    /// The visible screen with runs of intra-line whitespace collapsed to a single
    /// space. The grid renders cursor-positioned footer segments as the *actual*
    /// column gap (many spaces); collapsing restores a compact line so the
    /// distance-bounded `workingRe` (`[^\n]{0,40}`) matches as intended.
    private func normalizedScreen() -> String {
        Self.wsRe.replacingMatches(in: screen.visibleText(), with: " ")
    }

    /// The bottom `promptRegionRows` rows, whitespace-collapsed like `normalizedScreen`.
    private func normalizedBottom() -> String {
        Self.wsRe.replacingMatches(in: screen.bottomText(Self.promptRegionRows), with: " ")
    }

    // MARK: - patterns (ICU translations of the TS regexes)

    /// Rows of the bottom screen region treated as the footer / input / dialog area.
    /// Prose-like prompt markers are only matched here so the same words scrolled up
    /// in conversation history don't masquerade as a live prompt (juancode-8w5).
    private static let promptRegionRows = 20

    /// The "esc to interrupt" working line, tolerant of wording.
    private static let workingRe = Regex(
        #"\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b"#, caseInsensitive: true)

    /// Runs of spaces/tabs within a line (not newlines), collapsed before matching.
    private static let wsRe = Regex(#"[^\S\n]{2,}"#, caseInsensitive: false)

    /// A prompt marker with the region it is trusted in. The `❯ 1.` selection cursor
    /// is the CLI's own menu UI — never in prose — so it is matched across the whole
    /// screen (a centered trust/permission dialog paints its cursor above any fixed
    /// bottom band). Prose-like markers could appear as ordinary scrolled-up text, so
    /// they are trusted only in the bottom region.
    struct PromptPattern {
        let label: String
        let re: Regex
        let bottomOnly: Bool
    }

    private static let promptPatterns: [PromptPattern] = [
        PromptPattern(label: "select-cursor", re: Regex(#"❯\s*\d+\.\s"#, caseInsensitive: false), bottomOnly: false),
        PromptPattern(label: "do-you-want", re: Regex(#"\bDo you want to\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "do-you-trust", re: Regex(#"\bDo you trust\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "proceed", re: Regex(#"\bProceed\?"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "allow", re: Regex(#"\bAllow\b[^\n]{0,40}\?"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "yn-paren", re: Regex(#"\(y/n\)"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "yn-bracket", re: Regex(#"\[y/n\]"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "press-enter", re: Regex(#"\bPress Enter to continue\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "esc-cancel", re: Regex(#"\(esc to cancel\)"#, caseInsensitive: true), bottomOnly: true),
    ]

    /// Cheap lowercase substrings that gate the idle→waiting re-read: only a frame
    /// whose bytes could carry (part of) a prompt marker is worth re-scanning for. A
    /// false positive here just costs one wasted regex pass; it never alone changes state.
    private static let promptGate: [String] = ["?", "❯", "y/n", "trust", "continue", "esc to cancel"]
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
