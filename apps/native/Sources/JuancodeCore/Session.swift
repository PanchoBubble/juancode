import Foundation

public enum SessionError: Error {
    case spawnFailed
    case notResumable
    case notRunning
}

/// The result of seeding a fresh session with an initial prompt (`Session.autoSubmit`).
/// `.failed` carries a human-readable reason so the caller can surface it instead of
/// leaving the session silently idle with an undelivered prompt.
public enum AutoSubmitOutcome: Sendable, Equatable {
    case submitted
    case failed(reason: String)
}

/// Dependencies a `Session` needs, injected by the registry so tests can supply
/// fakes (in-memory store, fake binary resolver, stub codex discovery).
public struct SessionEnvironment: Sendable {
    public var resolver: BinaryResolver
    public var store: SessionStore
    /// Per-session outbound message queue (oracle-cj3 / juancode-r82): the
    /// session drives this on idle-edge transitions to deliver queued messages in
    /// order. Defaults to a process-local in-memory queue; the server injects the
    /// persisted one so the queue survives reconnects / restarts.
    public var messageQueue: MessageQueue
    public var scrollbackLimit: Int
    /// Discover a Codex CLI session id post-spawn. Defaults to the real scanner;
    /// tests override it. `(cwd, sinceMs) -> id?`.
    public var discoverCodexId: @Sendable (_ cwd: String, _ sinceMs: Int) async -> String?
    /// Read the CLI's generated title from its transcript. Injected from
    /// `JuancodeServices` (`deriveSessionTitle`) so the core stays dependency-free;
    /// defaults to nil (no title polling). `(provider, cliSessionId) -> title?`.
    public var deriveTitle: @Sendable (_ provider: ProviderId, _ cliSessionId: String) async -> String?
    /// Read the CLI transcript's token usage. Injected from `JuancodeServices`
    /// (`deriveSessionUsage`); defaults to nil. `(provider, cliSessionId) -> usage?`.
    public var deriveUsage: @Sendable (_ provider: ProviderId, _ cliSessionId: String) async -> SessionUsage?
    /// Start tailing the CLI's stream-json transcript for structured activity pulses
    /// (juancode-1c9), the preferred wording-independent busy/idle signal. Injected
    /// from `JuancodeServices` so the core stays dependency-free; the default is a
    /// no-op (screen-only detection, e.g. in tests). The session passes a *getter* for
    /// the CLI session id (Codex discovers it after spawn) and an `onBatch` callback
    /// receiving each parsed batch of transcript kinds + tool ids plus a `reset` flag
    /// (true for the one-shot backlog). Returns a stop handle the session calls on
    /// exit/kill.
    public var startActivityTail: @Sendable (
        _ provider: ProviderId,
        _ cliSessionId: @escaping @Sendable () -> String?,
        _ onBatch: @escaping @Sendable (_ batch: StructuredEventBatch, _ reset: Bool) -> Void
    ) -> (@Sendable () -> Void)

    public init(
        resolver: BinaryResolver = DefaultBinaryResolver(),
        store: SessionStore = InMemorySessionStore(),
        messageQueue: MessageQueue = MessageQueue(),
        scrollbackLimit: Int = 256 * 1024,
        discoverCodexId: @escaping @Sendable (String, Int) async -> String? = {
            await CodexSessionDiscovery.capture(cwd: $0, sinceMs: $1)
        },
        deriveTitle: @escaping @Sendable (ProviderId, String) async -> String? = { _, _ in nil },
        deriveUsage: @escaping @Sendable (ProviderId, String) async -> SessionUsage? = { _, _ in nil },
        startActivityTail: @escaping @Sendable (
            ProviderId,
            @escaping @Sendable () -> String?,
            @escaping @Sendable (StructuredEventBatch, Bool) -> Void
        ) -> (@Sendable () -> Void) = { _, _, _ in {} }
    ) {
        self.resolver = resolver
        self.store = store
        self.messageQueue = messageQueue
        self.scrollbackLimit = scrollbackLimit
        self.discoverCodexId = discoverCodexId
        self.deriveTitle = deriveTitle
        self.deriveUsage = deriveUsage
        self.startActivityTail = startActivityTail
    }
}

/// One live session = one pty running a real CLI, with fan-out to N subscribers.
/// Mirrors `apps/server/src/session.ts`. Title/usage polling (u34.6) and the
/// GRDB store (u34.5) plug in behind `SessionEnvironment`; here the store is the
/// in-memory default.
/// `@unchecked Sendable`: every mutable field (`_meta`, the listener maps,
/// `scroll`, `nextToken`, the persist/title bookkeeping) is read and written only
/// under `lock` (an `NSRecursiveLock`); the immutable collaborators (`env`,
/// `spec`, `workQueue`) are `let`. The lock is the synchronization invariant, so
/// the type is safe to share across the pty queue, the title-poll timer, and
/// caller threads.
public final class Session: @unchecked Sendable {
    /// A subscriber-cancel handle: call it to detach.
    public typealias Cancel = @Sendable () -> Void
    public typealias OutputListener = @Sendable (_ bytes: [UInt8]) -> Void
    public typealias ExitListener = @Sendable (_ exitCode: Int?) -> Void
    public typealias ActivityListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void
    /// Fires on every granted arbitrated resize (`owner` + the new dims) and on a
    /// real ownership release (`owner` nil, dims = last desired grid). The render
    /// side uses it to adopt a remote owner's grid while the local pane isn't
    /// driving (juancode-slz); the UI layer can watch it for "remote is driving"
    /// state (juancode-2t4).
    public typealias GridChangeListener = @Sendable (_ owner: String?, _ cols: Int, _ rows: Int) -> Void
    /// Fires when a persisted meta field changes out-of-band from a turn edge —
    /// the title/usage poll landing a CLI-generated title, a manual rename, an
    /// archive/dormant flip. The sidebar rebuilds its list from this; without it
    /// a derived title only surfaces on the next unrelated `refresh()` (juancode).
    public typealias MetaChangeListener = @Sendable (_ meta: SessionMeta) -> Void

    private let lock = NSRecursiveLock()
    private var _meta: SessionMeta
    private let env: SessionEnvironment
    private let spec: ProviderSpec
    private var proc: PtyProcess?

    private var scroll: Scrollback
    private var outputListeners: [Int: OutputListener] = [:]
    private var exitListeners: [Int: ExitListener] = [:]
    private var activityListeners: [Int: ActivityListener] = [:]
    private var gridListeners: [Int: GridChangeListener] = [:]
    private var metaListeners: [Int: MetaChangeListener] = [:]
    private var nextToken = 0

    private let workQueue: DispatchQueue
    private var detector: ActivityDetector!

    /// Headless VT engine for this session (juancode-a2h.1): a real SwiftTerm
    /// `Terminal` with no view, fed the pty stream once on `workQueue` in
    /// `handleData`. Runs ALONGSIDE the byte ring and the byte-fed detector during
    /// the epic's transition — nothing reads it yet; views become projections of it
    /// in a2h.2. Internally locked, so it's an immutable collaborator like `workQueue`.
    public let terminalModel: SessionTerminalModel

    /// Arbitrates which client controls this session's single shared pty grid, so
    /// two different-sized viewers can't flap it last-write-wins (juancode-1th.1).
    private let grid = GridArbiter()

    /// The controlling client's most recent desired grid, seeded with the spawn
    /// size and updated on every arbitrated resize. The server re-asserts it across
    /// the boot window so a CLI that installs its SIGWINCH handler late (slow MCP
    /// load) still lands at the right size — no client-side retry timers needed
    /// (juancode-1th.3). Guarded by `lock`.
    private var desiredCols = 0
    private var desiredRows = 0

    /// Previous activity, tracked to fire the queue flush on the edge into idle
    /// (oracle-cj3 / juancode-r82). Guarded by `lock`.
    private var prevQueueActivity: SessionActivity?
    /// True while `flushQueue` is mid-delivery, so overlapping edges don't double
    /// up a paste. Guarded by `lock`.
    private var flushingQueue = false

    private let persistDebounceMs = 2000
    private var persistGeneration = 0

    /// Throttles how eagerly the (capped) scrollback ring is written back, keeping
    /// the expensive full write (column + FTS reindex) off the per-output hot path.
    /// Guarded by `lock`. See `ScrollbackWriteThrottle` (juancode-5qw.1).
    private var writeThrottle = ScrollbackWriteThrottle(flushThresholdBytes: 128 * 1024)
    /// Previous activity, tracked to fire a full (FTS-reindexing) flush on the edge
    /// into idle — a turn boundary is when search wants the latest scrollback.
    /// Guarded by `lock`.
    private var prevPersistActivity: SessionActivity?

    private let titlePollMs = 4000
    private var titleTimer: DispatchSourceTimer?

    /// Stop handle for the structured-transcript activity tail (juancode-1c9),
    /// started at spawn and invoked on exit/kill. Guarded by `lock`; nil-ed after
    /// the first stop so it runs at most once.
    private var stopActivityTail: (@Sendable () -> Void)?

    /// Set once the user renames the session manually, so the CLI-derived title
    /// poll stops clobbering their chosen name.
    private var titleIsManual = false

    /// ms-since-epoch of the last input written to the pty (keystrokes, pastes,
    /// queue deliveries — everything funnels through `write`). Seeded with the
    /// spawn time. The idle reaper (juancode-lgq) uses it so a half-typed,
    /// unsubmitted prompt — invisible to the activity detector and the transcript
    /// — still protects the session from being reaped. Guarded by `lock`.
    private var _lastInputMs: Int

    public var meta: SessionMeta { lock.withLock { _meta } }
    public var id: String { lock.withLock { _meta.id } }
    public var isRunning: Bool { lock.withLock { _meta.status == .running } }
    public var activity: SessionActivity { detector.activity }
    public var lastInputMs: Int { lock.withLock { _lastInputMs } }

    /// The pty child's pid while the session is running, nil once exited. The
    /// idle reaper walks its descendants for the OS-ground-truth idle checks.
    public var childPid: pid_t? {
        lock.withLock { _meta.status == .running ? proc?.pid : nil }
    }

    // MARK: - factories

    /// Start a brand-new conversation.
    public static func create(
        provider: ProviderId,
        cwd: String,
        cols: Int,
        rows: Int,
        opts: SpawnOptions = SpawnOptions(),
        worktreePath: String? = nil,
        env: SessionEnvironment
    ) throws -> Session {
        let spec = Providers.spec(for: provider)
        let now = nowMs()
        let id = UUID().uuidString.lowercased()
        let folder = (cwd as NSString).lastPathComponent
        let meta = SessionMeta(
            id: id,
            provider: provider,
            cwd: cwd,
            title: "\(spec.label) · \(folder.isEmpty ? cwd : folder)",
            status: .running,
            exitCode: nil,
            createdAt: now,
            updatedAt: now,
            // Claude's id is pinned up front; Codex's is discovered post-spawn.
            cliSessionId: spec.pinsSessionId ? id : nil,
            skipPermissions: opts.skipPermissions,
            worktreePath: worktreePath,
            usage: nil
        )
        return try Session(meta: meta, args: spec.startArgs(id, opts), cols: cols, rows: rows,
                           isNew: true, env: env)
    }

    /// Revive an exited session by resuming its prior CLI conversation in a fresh
    /// pty, keeping the same juancode id. Requires a captured `cliSessionId`.
    public static func resume(
        _ prev: SessionMeta,
        cols: Int,
        rows: Int,
        priorScrollback: [UInt8] = [],
        env: SessionEnvironment
    ) throws -> Session {
        guard let cliSessionId = prev.cliSessionId else { throw SessionError.notResumable }
        let spec = Providers.spec(for: prev.provider)
        var meta = prev
        meta.status = .running
        meta.exitCode = nil
        meta.dormant = false // waking a reaped session — it's live again
        meta.updatedAt = nowMs()
        let opts = SpawnOptions(skipPermissions: meta.skipPermissions)
        return try Session(meta: meta, args: spec.resumeArgs(cliSessionId, opts), cols: cols, rows: rows,
                           isNew: false, env: env, seedScrollback: priorScrollback)
    }

    /// Restart an exited session as a brand-new CLI conversation in place, keeping
    /// the same juancode id (and pane/db row). For pinned-id providers (Claude) a
    /// *fresh* CLI session id is pinned so the first completed turn writes a resumable
    /// transcript and future revives can `--resume` it; discovered providers (Codex)
    /// reset to nil so post-spawn discovery recaptures the id. A fresh pin (rather
    /// than reusing the old one) avoids Claude's "session id already in use" error
    /// when a stale transcript for the old id lingers. Used when a session can't be
    /// resumed because it never produced a transcript — booting fresh beats a dead
    /// replay-only pane.
    public static func restartFresh(
        _ prev: SessionMeta,
        cols: Int,
        rows: Int,
        env: SessionEnvironment
    ) throws -> Session {
        let spec = Providers.spec(for: prev.provider)
        var meta = prev
        meta.status = .running
        meta.exitCode = nil
        meta.dormant = false
        meta.updatedAt = nowMs()
        let freshPin = UUID().uuidString.lowercased()
        meta.cliSessionId = spec.pinsSessionId ? freshPin : nil
        let opts = SpawnOptions(skipPermissions: meta.skipPermissions)
        let startId = spec.pinsSessionId ? freshPin : prev.id
        return try Session(meta: meta, args: spec.startArgs(startId, opts), cols: cols, rows: rows,
                           isNew: false, env: env)
    }

    // MARK: - init

    private init(
        meta: SessionMeta,
        args: [String],
        cols: Int,
        rows: Int,
        isNew: Bool,
        env: SessionEnvironment,
        seedScrollback: [UInt8] = []
    ) throws {
        self._meta = meta
        self.env = env
        self._lastInputMs = nowMs()
        self.spec = Providers.spec(for: meta.provider)
        self.scroll = Scrollback(limit: env.scrollbackLimit, seed: seedScrollback)
        self.workQueue = DispatchQueue(label: "juancode.session.\(meta.id)")
        // Bound the parsed-scrollback memory sensibly against the byte-ring cap
        // (~64 bytes/line is a conservative average for wrapped agent output).
        self.terminalModel = SessionTerminalModel(
            cols: cols, rows: rows, scrollbackLines: max(2000, env.scrollbackLimit / 64))

        self.detector = ActivityDetector(cols: cols, rows: rows) { [weak self] state, notify in
            self?.emitActivity(state, notify)
        }

        let command = env.resolver.command(for: meta.provider)
        guard let proc = PtyProcess(
            executable: command,
            args: args,
            cwd: meta.cwd,
            cols: cols,
            rows: rows,
            queue: workQueue,
            onData: { [weak self] bytes in self?.handleData(bytes) },
            onExit: { [weak self] code in self?.handleExit(code) }
        ) else {
            throw SessionError.spawnFailed
        }
        self.proc = proc

        if isNew {
            env.store.insert(meta)
        } else {
            env.store.update(meta, scrollback: scroll.replay)
        }

        // For Codex we can't pin the session id, so discover it from the rollout file.
        if !spec.pinsSessionId && meta.cliSessionId == nil {
            captureCliSessionId()
        }

        // Keep the title + usage in sync with the CLI's own transcript.
        startTitleWatch()
        // Preferred activity signal: pulse the detector busy on each batch of agent
        // records the CLI appends to its transcript. The id is read via a getter so
        // Codex (which discovers its id after spawn) starts tailing once it lands. The
        // backlog (`reset: true`) is skipped so a resumed session's replayed prior turns
        // don't spuriously pulse busy at startup — only newly appended records count.
        let stop = env.startActivityTail(
            meta.provider,
            { [weak self] in self?.meta.cliSessionId },
            { [weak self] batch, reset in
                if !reset { self?.detector.feedStructured(batch) }
            }
        )
        lock.withLock { stopActivityTail = stop }
        // Seed the desired grid with the spawn size and re-assert it once the TUI is
        // up, so a slow-booting CLI that missed early SIGWINCHs still adopts it
        // (juancode-1th.3) — the server-side replacement for per-client retry timers.
        lock.withLock {
            desiredCols = cols
            desiredRows = rows
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.reapplyGridWhenReady()
        }
    }

    /// Invoke and clear the activity-tail stop handle (idempotent).
    private func stopActivityTailIfNeeded() {
        let stop = lock.withLock { () -> (@Sendable () -> Void)? in
            let s = stopActivityTail
            stopActivityTail = nil
            return s
        }
        stop?()
    }

    // MARK: - pty callbacks (on workQueue)

    private func handleData(_ bytes: [UInt8]) {
        let flushNow = lock.withLock { () -> Bool in
            scroll.append(bytes)
            return writeThrottle.onOutput(bytes.count)
        }
        detector.feed(bytes)
        // Parse into the headless model once, here on the workQueue (juancode-a2h.1).
        // Additive during the epic's transition — no consumer yet.
        terminalModel.feed(bytes)
        for l in snapshotOutput() { l(bytes) }
        // Mid-burst crash-safety flush once enough new output has piled up (a
        // continuously streaming session never pauses long enough to trip the
        // trailing debounce), otherwise (re)arm the debounce for the tail.
        if flushNow { flushScrollbackOnly() }
        schedulePersist()
    }

    private func handleExit(_ code: Int32) {
        lock.withLock {
            _meta.status = .exited
            _meta.exitCode = Int(code)
            _meta.updatedAt = nowMs()
        }
        detector.reset()
        stopTitleWatch()
        stopActivityTailIfNeeded()
        // One last transcript read to catch a late-generated title / final usage.
        refreshTitleAndUsage()
        persistNow()
        let listeners = lock.withLock { Array(exitListeners.values) }
        for l in listeners { l(Int(code)) }
    }

    private func emitActivity(_ state: SessionActivity, _ notify: Bool) {
        for l in lock.withLock({ Array(activityListeners.values) }) { l(state, notify) }
        maybeFlushQueueOnEdge(state)
        maybePersistOnIdleEdge(state)
    }

    /// On the edge into idle (a turn boundary), do a full flush so search picks up the
    /// turn's output. No-op unless something new was written since the last full
    /// flush, so a chattery detector flipping idle->busy->idle can't spam full writes.
    private func maybePersistOnIdleEdge(_ state: SessionActivity) {
        let shouldFlush = lock.withLock { () -> Bool in
            let was = prevPersistActivity
            prevPersistActivity = state
            return state == .idle && was != nil && was != .idle && writeThrottle.ftsStale
        }
        if shouldFlush { persistNow() }
    }

    // MARK: - input / lifecycle

    public func write(_ bytes: [UInt8]) {
        lock.withLock { _lastInputMs = nowMs() }
        if isRunning { proc?.write(bytes) }
    }

    public func write(_ text: String) {
        write(Array(text.utf8))
    }

    // MARK: - seeding a fresh session (autoSubmit)

    /// Tunables for the verified initial-prompt delivery in `autoSubmit`.
    private enum Seed {
        /// Cap on waiting for the TUI to settle before pasting (MCP loading on
        /// startup can be slow); we paste anyway once it elapses.
        static let readyMaxMs = 45_000
        static let readyPollMs = 200
        /// Per-attempt budget to confirm the paste landed in the input box.
        static let landMs = 2_000
        /// Total budget for the paste to land, re-pasting every `landMs`. Generous so
        /// an input box that only becomes interactive several seconds after the screen
        /// first looks stable (concurrent spawns, slow MCP startup) is still caught,
        /// instead of giving up after a couple of tries.
        static let landDeadlineMs = 24_000
        /// Per-attempt budget to confirm the Enter submitted (agent went busy or
        /// the prompt left the input box).
        static let submitMs = 4_000
        /// Settle gap between the bracketed-paste end (`ESC[201~`) and the
        /// submitting Enter, so the CR never races the still-open paste and get
        /// swallowed as a literal newline. Mirrors `pasteAndSubmit`'s delay; the
        /// symptom without it shows up when the laptop is locked (App Nap
        /// coalesces the land-poll to zero, so the CR would fire instantly).
        static let submitSettleMs = 200
        static let pollMs = 150
        static let maxAttempts = 3
        /// Rows of the bottom screen region treated as the input-box area.
        static let inputRows = 16
    }

    /// Tunables for the server-owned desired-grid re-apply (juancode-1th.3). Mirrors
    /// the `GRID` block in `apps/server/src/session.ts`.
    private enum GridReapply {
        /// Settle-check rounds across the boot window; the nudge fires at most once,
        /// on the first round whose screen genuinely settles.
        static let attempts = 3
        /// Per-round budget for the TUI to settle (stable frames).
        static let settleMaxMs = 8_000
        static let settlePollMs = 200
        /// Gap between the `rows-1` nudge and the real `rows` (a genuine size change).
        static let nudgeMs = 60
    }

    /// Seed a fresh session with an initial prompt and **verify** it was actually
    /// delivered, retrying on failure and reporting the outcome via `onResult`
    /// instead of leaving the session silently idle with an unsent prompt.
    ///
    /// The old approach fired on the *first* output byte then pasted blind after a
    /// fixed delay — but the first byte is the startup banner / MCP-loading chatter,
    /// emitted seconds before the input box is in raw mode, so the paste could land
    /// nowhere and the prompt would just rot in the box. Instead we:
    ///   1. wait for the screen to *settle* (stable frames) so the input box is up,
    ///   2. paste (bracketed `ESC[200~ … ESC[201~`) and confirm a signature of the
    ///      prompt appears in the input-box region, re-pasting if it didn't,
    ///   3. send a lone Enter and confirm submission — the agent goes busy or the
    ///      prompt leaves the box — re-sending Enter if it didn't.
    /// The bracketed-paste-then-separate-Enter split is still essential: a
    /// `"\(text)\r"` burst makes the CLI read the chunk as a paste and keep the CR
    /// as a literal newline, leaving the prompt unsent.
    public func autoSubmit(_ text: String, onResult: (@Sendable (AutoSubmitOutcome) -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onResult?(.submitted); return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { onResult?(.failed(reason: "session was released")); return }
            let outcome = await self.deliverSeed(trimmed)
            onResult?(outcome)
        }
    }

    /// The verified delivery state machine for `autoSubmit`. Runs off the main
    /// actor; every collaborator it touches (`write`, `isRunning`, `detector`) is
    /// thread-safe.
    private func deliverSeed(_ trimmed: String) async -> AutoSubmitOutcome {
        // Keep App Nap from throttling the settle/land/submit timers while the
        // laptop is locked or the app is occluded — coalesced `Task.sleep`s
        // collapse the paste→Enter gap and the CR gets eaten as a newline, so
        // the prompt lands but never submits.
        let activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "Delivering initial prompt to a fresh session")
        defer { ProcessInfo.processInfo.endActivity(activityToken) }

        let signature = InitialPromptDelivery.signature(for: trimmed)

        // 1) Wait for the TUI to settle so the input box exists before we paste.
        await waitForStableScreen(maxMs: Seed.readyMaxMs, pollMs: Seed.readyPollMs)
        guard isRunning else { return .failed(reason: "session exited during startup") }

        // 2) Paste, then confirm the prompt actually landed in the input box.
        // `waitForStableScreen` can report "settled" on an early partial paint — the
        // banner is up but the input box isn't interactive yet — especially when
        // several sessions spawn at once and contend for CPU. So don't give up after
        // a fixed few tries: keep re-pasting until it lands or a generous deadline
        // passes, so a box that only becomes ready seconds later is still caught.
        var landed = false
        var elapsedMs = 0
        while elapsedMs < Seed.landDeadlineMs {
            guard isRunning else { return .failed(reason: "session exited before the prompt was typed") }
            if activity == .busy { return .submitted } // already working — nothing to do
            paste(trimmed)
            landed = await waitUntil(maxMs: Seed.landMs, pollMs: Seed.pollMs) {
                self.activity == .busy || self.inputBoxContains(signature)
                    || self.inputBoxShowsCollapsedPaste()
            }
            if activity == .busy { return .submitted }
            if landed { break }
            elapsedMs += Seed.landMs
        }
        guard landed else {
            return .failed(
                reason: "the prompt never appeared in the input box after \(Seed.landDeadlineMs / 1000)s")
        }

        // 3) Submit, then confirm it went through (agent busy, or the box cleared).
        // Let the paste-end sequence settle before the CR so the CLI is out of
        // paste mode and reads the Enter as submit, not a literal newline.
        try? await Task.sleep(for: .milliseconds(Seed.submitSettleMs))
        for _ in 0..<Seed.maxAttempts {
            guard isRunning else { return .failed(reason: "session exited before the prompt was submitted") }
            write("\r")
            let submitted = await waitUntil(maxMs: Seed.submitMs, pollMs: Seed.pollMs) {
                self.activity == .busy
                    || (!self.inputBoxContains(signature) && !self.inputBoxShowsCollapsedPaste())
            }
            if submitted { return .submitted }
        }
        return .failed(reason: "the prompt stayed in the input box; it was never submitted")
    }

    /// True if the prompt `signature` is currently visible in the input-box region.
    /// Empty signature (all-whitespace prompt) is treated as "present" so delivery
    /// of a content-free seed doesn't loop — though `autoSubmit` rejects those up front.
    private func inputBoxContains(_ signature: String) -> Bool {
        guard !signature.isEmpty else { return true }
        return InitialPromptDelivery.region(detector.inputRegionSnapshot(rows: Seed.inputRows),
                                            contains: signature)
    }

    /// True if the input-box region shows a collapsed-paste chip (Claude renders one
    /// for a large/multi-line paste in place of the literal text), which the seed
    /// loop treats as the paste having landed. See `InitialPromptDelivery`.
    private func inputBoxShowsCollapsedPaste() -> Bool {
        InitialPromptDelivery.regionShowsCollapsedPaste(detector.inputRegionSnapshot(rows: Seed.inputRows))
    }

    /// Poll until the rendered screen stops changing (two identical, non-empty
    /// frames `pollMs` apart) or `maxMs` elapses — a CLI-agnostic "TUI is ready"
    /// signal that replaces trusting the first output byte. Returns whether the
    /// screen actually settled (false = it was still changing at `maxMs`), so a
    /// caller can tell "ready" from "busy streaming" and avoid disturbing the
    /// latter.
    @discardableResult
    private func waitForStableScreen(maxMs: Int, pollMs: Int) async -> Bool {
        var elapsed = 0
        var prev = detector.screenSnapshot()
        while elapsed < maxMs {
            try? await Task.sleep(for: .milliseconds(pollMs))
            elapsed += pollMs
            let cur = detector.screenSnapshot()
            if !cur.isEmpty && cur == prev { return true }
            prev = cur
        }
        return false
    }

    /// Poll `cond` every `pollMs` until it's true or `maxMs` elapses; returns whether
    /// it became true.
    private func waitUntil(maxMs: Int, pollMs: Int, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
        if cond() { return true }
        var elapsed = 0
        while elapsed < maxMs {
            try? await Task.sleep(for: .milliseconds(pollMs))
            elapsed += pollMs
            if cond() { return true }
        }
        return false
    }

    /// Paste `text` and submit it into an **already-live** session whose TUI is
    /// up, without waiting for output first. `autoSubmit` waits for the startup
    /// render before pasting; that listener never fires for a session that's
    /// idle (agent done, TUI static, no new output), so a mid-session injection
    /// — e.g. the PR-tracker pushing a follow-up prompt — must paste straight
    /// away. Same bracketed-paste + separate-Enter delivery: writing
    /// `"\(text)\r"` in one burst lets the CLI misread the chunk as a paste and
    /// keep the CR as a literal newline, leaving the prompt unsent in the box.
    public func submit(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onResult?(.delivered); return }
        deliverPaste(trimmed, submit: true, onResult: onResult)
    }

    /// Insert `text` into an already-live session's prompt **without** submitting
    /// — a bracketed paste with no trailing Enter, so the user can review/edit it
    /// before sending. Used by the ⌘K prompt-template palette's "insert" action
    /// (juancode-2vd) and the batched review submission. `submit` is the same
    /// delivery plus the separate Enter. `onResult` reports oversize rejection /
    /// mid-paste abort so the caller can surface it.
    public func insert(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onResult?(.delivered); return }
        deliverPaste(trimmed, submit: false, onResult: onResult)
    }

    /// Tunables for chunked programmatic paste delivery (`PasteEngine`).
    private enum Paste {
        /// Settle gap between the paste and the submitting Enter, so the CR isn't
        /// swallowed as a literal newline inside a still-open paste. Mirrors the
        /// seed path's `submitSettleMs`.
        static let submitSettleMs = 150
        /// Per-chunk write budget. A chunk that doesn't flush within this (child
        /// wedged, pty buffer stuck) aborts the operation loudly instead of hanging
        /// the caller forever.
        static let chunkTimeoutMs = 5_000
    }

    /// Program-aware paste policy for this session (bracketed iff the CLI reads
    /// bracketed-paste markers).
    private var pastePolicy: PasteEngine.Policy {
        var policy = PasteEngine.Policy.agentPrompt
        policy.bracketed = spec.bracketedPaste
        return policy
    }

    /// Plan `text` through the `PasteEngine`, then deliver its chunks serially with
    /// backpressure and a per-chunk timeout. Over-size text is rejected up front; a
    /// session that dies (or a chunk that stalls) mid-paste aborts loudly via
    /// `onResult` rather than silently wedging the TUI. Delivery runs off the main
    /// thread; every collaborator it touches is thread-safe.
    private func deliverPaste(_ text: String, submit: Bool, onResult: (@Sendable (PasteOutcome) -> Void)?) {
        switch PasteEngine.plan(text, policy: pastePolicy) {
        case .reject(let reason):
            onResult?(.rejected(reason: reason))
        case .deliver(let chunks):
            guard !chunks.isEmpty else { onResult?(.delivered); return }
            guard isRunning else { onResult?(.aborted(reason: "session isn't running")); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { onResult?(.aborted(reason: "session was released")); return }
                // Evaluate the delivery FIRST, then report it. Writing it as
                // `onResult?(runPasteDelivery(...))` short-circuits the whole
                // expression when `onResult` is nil — Swift never evaluates the
                // argument — so a fire-and-forget paste (seed/queue flush, which pass
                // no callback) would never actually deliver.
                let outcome = self.runPasteDelivery(chunks: chunks, submit: submit)
                onResult?(outcome)
            }
        }
    }

    /// Write `chunks` one at a time, waiting for each to flush before the next
    /// (backpressure), then optionally send the submitting Enter after a settle
    /// gap. Blocks its background thread on a per-chunk semaphore; a stall past
    /// `chunkTimeoutMs` or a dead session returns `.aborted`.
    private func runPasteDelivery(chunks: [[UInt8]], submit: Bool) -> PasteOutcome {
        for chunk in chunks {
            guard isRunning, let proc else { return .aborted(reason: "session exited during paste") }
            let sem = DispatchSemaphore(value: 0)
            let ok = FlagBox()
            proc.write(chunk) { flushed in
                ok.value = flushed
                sem.signal()
            }
            if sem.wait(timeout: .now() + .milliseconds(Paste.chunkTimeoutMs)) == .timedOut {
                return .aborted(reason: "paste stalled — a chunk didn't flush within \(Paste.chunkTimeoutMs)ms")
            }
            guard ok.value else { return .aborted(reason: "the pty rejected the paste (session may be exiting)") }
        }
        if submit {
            guard isRunning else { return .aborted(reason: "session exited before the paste was submitted") }
            Thread.sleep(forTimeInterval: Double(Paste.submitSettleMs) / 1000)
            guard isRunning else { return .aborted(reason: "session exited before the paste was submitted") }
            write([0x0D]) // carriage return submits
        }
        return .delivered
    }

    /// Write `trimmed` as a bracketed paste (`ESC[200~ … ESC[201~`) without the
    /// submitting Enter — `autoSubmit` pastes, verifies it landed, then submits
    /// separately. Fire-and-forget; the seed loop verifies the landing itself.
    private func paste(_ trimmed: String) {
        deliverPaste(trimmed, submit: false, onResult: nil)
    }

    // MARK: - outbound message queue (oracle-cj3 / juancode-r82)

    /// Tunables for delivering queued messages on an idle transition. Mirrors the
    /// `QUEUE` constants in `apps/server/src/session.ts`.
    private enum Queue {
        /// How long to confirm a delivered message took (the agent went busy).
        static let acceptMs = 4_000
        static let pollMs = 120
    }

    /// Nudge the queue when a message is added while the session is already idle —
    /// otherwise the next message would wait for an activity edge that never comes.
    /// Safe to call any time; it no-ops unless idle with something to deliver.
    public func kickQueue() {
        if isRunning && activity == .idle { startFlushQueue() }
    }

    /// Fire the queue flush only on a real transition *into* idle (turn boundary).
    private func maybeFlushQueueOnEdge(_ state: SessionActivity) {
        let was: SessionActivity? = lock.withLock {
            let prev = prevQueueActivity
            prevQueueActivity = state
            return prev
        }
        if state == .idle && was != nil && was != .idle { startFlushQueue() }
    }

    /// Run the flush off the main actor; every collaborator it touches is thread-safe.
    private func startFlushQueue() {
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.flushQueue()
        }
    }

    /// Deliver queued messages one at a time while the session sits idle. Each is
    /// sent with the same bracketed-paste-then-Enter the seed / submit paths use (a
    /// `"\(text)\r"` burst is read as a paste with the CR kept literal, so it never
    /// submits). We pop a message only once we've confirmed it landed the agent in
    /// `busy`; that also ends this pass — the agent finishing the turn fires the
    /// next idle edge, which delivers the next message in order. A stalled delivery
    /// is left queued and retried on the next idle / kick rather than spun on.
    /// Mirrors `flushQueue` in `apps/server/src/session.ts`.
    private func flushQueue() async {
        let claimed = lock.withLock { () -> Bool in
            if flushingQueue { return false }
            flushingQueue = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { flushingQueue = false } }

        while isRunning && activity == .idle {
            guard let item = env.messageQueue.peek(id) else { break }
            deliverPaste(item.text, submit: true, onResult: nil)
            if !isRunning { break }
            let accepted = await waitUntil(maxMs: Queue.acceptMs, pollMs: Queue.pollMs) {
                self.activity == .busy || !self.isRunning
            }
            // Drop the message only once it actually took; otherwise leave it queued
            // and stop, so a stalled delivery is retried on the next idle / kick.
            if accepted && activity == .busy {
                env.messageQueue.remove(id, item.id)
            }
            break
        }
    }

    /// Resize the pty grid. Returns whether the grid reached the live pty (false
    /// when the session isn't running yet — the resize is then dropped and a
    /// sequenced remote client can re-assert it, juancode-uz6).
    @discardableResult
    public func resize(cols: Int, rows: Int) -> Bool {
        let applied = isRunning ? (proc?.resize(cols: cols, rows: rows) ?? false) : false
        detector.resize(cols: cols, rows: rows)
        terminalModel.resize(cols: cols, rows: rows)
        return applied
    }

    /// Arbitrated grid resize for a specific client (juancode-1th.1). Only the
    /// *controlling* owner may write the shared pty grid; a non-owner's request is
    /// denied so the CLI TUI never flaps between two viewers' sizes. `applied` is
    /// whether the grid reached a live pty (as `resize`); `denied` is true when
    /// another client owns the grid — the caller renders the pty's actual grid
    /// as-is, and the `resizeAck.denied` flag tells its tracker to stop retrying.
    public func resizeGrid(owner: String, cols: Int, rows: Int) -> (applied: Bool, denied: Bool) {
        guard grid.request(owner) else { return (applied: false, denied: true) }
        // Remember the controlling owner's grid so the server can re-assert it if
        // this resize raced the CLI's SIGWINCH-handler install (juancode-1th.3).
        if cols > 0, rows > 0 {
            lock.withLock {
                desiredCols = cols
                desiredRows = rows
            }
        }
        let applied = resize(cols: cols, rows: rows)
        emitGridChange(owner: owner, cols: cols, rows: rows)
        return (applied: applied, denied: false)
    }

    /// Grid resize from the in-process local view (the native app's own terminal),
    /// which preempts remote viewers per the "native is the primary surface"
    /// policy (juancode-1th.1). Returns whether the grid reached a live pty.
    @discardableResult
    public func resizeLocal(cols: Int, rows: Int) -> Bool {
        resizeGrid(owner: GridArbiter.localOwner, cols: cols, rows: rows).applied
    }

    /// The grid the live pty has actually applied (`TIOCGWINSZ` readback), or nil
    /// when the session isn't running. A client compares this against its surface
    /// grid to repair only on true drift — verifying beats re-sending blindly,
    /// because every forced SIGWINCH makes the CLI's TUI repaint for nothing.
    public func appliedGrid() -> (cols: Int, rows: Int)? {
        isRunning ? proc?.currentGrid() : nil
    }

    /// Release this session's grid ownership held by `owner` — its client
    /// disconnected, or (for the local view) its terminal was torn down — so the
    /// next client's resize can take over the grid (juancode-1th.1). No-op if
    /// `owner` isn't the current owner.
    public func releaseGrid(owner: String) {
        guard grid.release(owner) else { return }
        let (cols, rows) = lock.withLock { (desiredCols, desiredRows) }
        emitGridChange(owner: nil, cols: cols, rows: rows)
    }

    /// The client currently controlling this session's pty grid
    /// (`GridArbiter.current`), or nil when unclaimed. `GridArbiter.localOwner`
    /// is the native app's own pane; anything else is a remote viewer.
    public func gridOwner() -> String? {
        grid.current
    }

    /// True while a remote viewer (web / phone) owns the pty grid — the native
    /// pane should render at the remote grid instead of fighting for ownership
    /// (juancode-slz); the UI layer can surface "remote is driving" from this
    /// (juancode-2t4).
    public var isGridRemotelyOwned: Bool {
        RemoteGridFit.isRemote(owner: grid.current)
    }

    /// Re-assert the desired grid once the TUI is up (juancode-1th.3). A CLI that
    /// installs its SIGWINCH handler late (slow MCP load) can miss a resize that
    /// landed during boot; once the screen settles, one genuine SIGWINCH makes it
    /// re-read the size — and one is enough, a settled TUI is fully initialized.
    /// The nudge fires ONLY on a genuinely settled screen: forcing it into a CLI
    /// that's actively streaming (resumed mid-turn, auto-submitted prompt) makes
    /// the TUI full-redraw twice mid-stream and lands mis-rendered frames in
    /// scrollback permanently — the "terminal garbles without any resize" bug. If
    /// the screen never settles across the rounds, skip entirely: a streaming CLI
    /// is demonstrably rendering, and any later real client resize re-asserts the
    /// grid anyway. Runs server-side so no client needs its own retry timers.
    private func reapplyGridWhenReady() async {
        for _ in 0..<GridReapply.attempts {
            let settled = await waitForStableScreen(maxMs: GridReapply.settleMaxMs,
                                                    pollMs: GridReapply.settlePollMs)
            guard isRunning else { return }
            if settled {
                nudgeReapply()
                return
            }
        }
    }

    /// Push the desired grid to the pty as a `rows-1` → `rows` pair: a genuine size
    /// change forces a SIGWINCH the settled CLI can't miss, where re-sending the
    /// same size can be a no-op. No-op until a desired grid is known / the pty is
    /// live.
    private func nudgeReapply() {
        let (cols, rows) = lock.withLock { (desiredCols, desiredRows) }
        guard isRunning, cols > 0, rows > 0 else { return }
        _ = resize(cols: cols, rows: rows > 2 ? rows - 1 : rows + 1)
        let workQueue = self.workQueue
        workQueue.asyncAfter(deadline: .now() + .milliseconds(GridReapply.nudgeMs)) { [weak self] in
            guard let self, self.isRunning else { return }
            _ = self.resize(cols: cols, rows: rows)
        }
    }

    public func kill() {
        stopTitleWatch()
        stopActivityTailIfNeeded()
        if isRunning { proc?.terminate() }
    }

    /// Mark the session dormant and persist the flag, then let the caller `kill()`
    /// it: the idle reaper (juancode-lgq) flags *before* killing so the persisted
    /// row `handleExit` finalises already carries `dormant = true` and the UI can
    /// tell "reaped while idle, wake me on demand" from a crash/exit. The flag is
    /// cleared by `Session.resume`.
    public func markDormant() {
        lock.withLock { _meta.dormant = true }
        persistMeta(titleChanged: false)
    }

    public func getScrollback() -> [UInt8] {
        lock.withLock { scroll.replay }
    }

    // MARK: - fan-out

    /// Subscribe to output bytes. With `replay: true` (default) the current
    /// scrollback is delivered immediately so a late subscriber paints history,
    /// exactly as the WS layer does on (re)attach. Returns a cancel handle.
    @discardableResult
    public func subscribeOutput(replay: Bool = true, _ listener: @escaping OutputListener) -> Cancel {
        let (token, replayBytes): (Int, [UInt8]) = lock.withLock {
            let t = nextToken; nextToken += 1
            outputListeners[t] = listener
            return (t, replay ? scroll.replay : [])
        }
        if replay && !replayBytes.isEmpty { listener(replayBytes) }
        return { [weak self] in self?.lock.withLock { _ = self?.outputListeners.removeValue(forKey: token) } }
    }

    @discardableResult
    public func onExit(_ listener: @escaping ExitListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            exitListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.exitListeners.removeValue(forKey: token) } }
    }

    @discardableResult
    public func onActivity(_ listener: @escaping ActivityListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            activityListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.activityListeners.removeValue(forKey: token) } }
    }

    /// Subscribe to arbitrated grid-state changes (see `GridChangeListener`).
    /// Listeners are invoked on the caller's queue of the resize/release that
    /// triggered them — hop to your own executor before touching UI.
    @discardableResult
    public func onGridChange(_ listener: @escaping GridChangeListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            gridListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.gridListeners.removeValue(forKey: token) } }
    }

    private func emitGridChange(owner: String?, cols: Int, rows: Int) {
        let listeners = lock.withLock { Array(gridListeners.values) }
        for l in listeners { l(owner, cols, rows) }
    }

    /// Subscribe to persisted meta changes (see `MetaChangeListener`). Fires on
    /// the queue that made the edit (the title-poll timer, a caller thread) — hop
    /// to your own executor before touching UI.
    @discardableResult
    public func onMetaChange(_ listener: @escaping MetaChangeListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            metaListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.metaListeners.removeValue(forKey: token) } }
    }

    private func emitMetaChange(_ meta: SessionMeta) {
        for l in lock.withLock({ Array(metaListeners.values) }) { l(meta) }
    }

    private func snapshotOutput() -> [OutputListener] {
        lock.withLock { Array(outputListeners.values) }
    }

    // MARK: - title / usage polling

    /// Poll the CLI transcript every `titlePollMs` so the title + token usage
    /// reflect the live session (mirrors `startTitleWatch` in session.ts). The
    /// derive closures come from `SessionEnvironment` (injected by the server/app
    /// from `JuancodeServices`), keeping the core dependency-free.
    private func startTitleWatch() {
        guard titleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + .milliseconds(titlePollMs),
                       repeating: .milliseconds(titlePollMs))
        timer.setEventHandler { [weak self] in self?.refreshTitleAndUsage() }
        titleTimer = timer
        timer.resume()
        refreshTitleAndUsage() // immediate first read
    }

    private func stopTitleWatch() {
        titleTimer?.cancel()
        titleTimer = nil
    }

    private func refreshTitleAndUsage() {
        Task { [weak self] in
            await self?.refreshTitle()
            await self?.refreshUsage()
        }
    }

    /// Rename the live session: persist a new title and pin it so the CLI-derived
    /// title poll won't overwrite the user's choice. No-op for an unchanged name.
    public func setTitle(_ title: String) {
        let changed = lock.withLock { () -> Bool in
            titleIsManual = true
            guard title != _meta.title else { return false }
            _meta.title = title
            return true
        }
        if changed { persistMeta(titleChanged: true) }
    }

    /// Archive / unarchive the live session and persist the flag.
    public func setArchived(_ archived: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard archived != _meta.archived else { return false }
            _meta.archived = archived
            return true
        }
        if changed { persistMeta(titleChanged: false) }
    }

    /// Read the CLI's generated title (or first prompt) and persist if changed.
    private func refreshTitle() async {
        let (cliSessionId, provider, manual) = lock.withLock { (_meta.cliSessionId, _meta.provider, titleIsManual) }
        guard !manual else { return } // user renamed it — don't clobber
        guard let cliSessionId else { return } // Codex id not discovered yet
        guard let title = await env.deriveTitle(provider, cliSessionId) else { return }
        let changed = lock.withLock { () -> Bool in
            guard title != _meta.title else { return false }
            _meta.title = title
            return true
        }
        if changed { persistMeta(titleChanged: true) }
    }

    /// Read the CLI transcript's token usage and persist if it changed.
    private func refreshUsage() async {
        let (cliSessionId, provider) = lock.withLock { (_meta.cliSessionId, _meta.provider) }
        guard let cliSessionId else { return }
        guard let usage = await env.deriveUsage(provider, cliSessionId) else { return }
        let changed = lock.withLock { () -> Bool in
            guard usage.totalTokens != (_meta.usage?.totalTokens ?? -1) else { return false }
            _meta.usage = usage
            return true
        }
        if changed { persistMeta(titleChanged: false) }
    }

    // MARK: - codex id discovery + persistence

    private func captureCliSessionId() {
        let since = nowMs()
        let cwd = lock.withLock { _meta.cwd }
        let id = lock.withLock { _meta.id }
        Task { [weak self] in
            guard let self else { return }
            let captured = await self.env.discoverCodexId(cwd, since)
            guard let captured else { return }
            let shouldSet = self.lock.withLock { () -> Bool in
                // Don't clobber a value set by a later resume.
                guard self._meta.cliSessionId == nil else { return false }
                self._meta.cliSessionId = captured
                return true
            }
            if shouldSet { self.env.store.setCliSessionId(id, cliSessionId: captured) }
        }
    }

    private func schedulePersist() {
        let gen = lock.withLock { () -> Int in persistGeneration += 1; return persistGeneration }
        workQueue.asyncAfter(deadline: .now() + .milliseconds(persistDebounceMs)) { [weak self] in
            guard let self, self.lock.withLock({ gen == self.persistGeneration }) else { return }
            self.flushScrollbackOnly()
        }
    }

    /// Crash-safety flush of the scrollback column only — no metadata write, no FTS
    /// reindex (juancode-5qw.1). Driven by the output debounce and the mid-burst
    /// byte-threshold flush; search is refreshed on the busy->idle edge / exit.
    private func flushScrollbackOnly() {
        let (id, bytes, updatedAt) = lock.withLock { () -> (String, [UInt8], Int) in
            _meta.updatedAt = nowMs()
            persistGeneration += 1 // cancel any pending debounce
            writeThrottle.didFlushScrollback()
            return (_meta.id, scroll.replay, _meta.updatedAt)
        }
        env.store.updateScrollback(id, scrollback: bytes, updatedAt: updatedAt)
    }

    /// Persist a metadata edit (title/usage/archive/dormant) via the meta-only write
    /// path so it doesn't rewrite the scrollback column or re-tokenize its FTS row
    /// (juancode-5qw.1). `titleChanged` reindexes the FTS title (reusing the stored
    /// scrollback). Always notifies — a meta edit moves the sidebar.
    private func persistMeta(titleChanged: Bool) {
        let meta = lock.withLock { () -> SessionMeta in
            _meta.updatedAt = nowMs()
            return _meta
        }
        env.store.updateMeta(meta, reindexTitleFts: titleChanged)
        emitMetaChange(meta)
    }

    /// Full persist: metadata + scrollback + FTS reindex — the heavy write, reserved
    /// for the busy->idle edge and exit, where search needs to catch up. Pass
    /// `notify: true` to rebuild the sidebar.
    private func persistNow(notify: Bool = false) {
        let (meta, bytes) = lock.withLock { () -> (SessionMeta, [UInt8]) in
            _meta.updatedAt = nowMs()
            persistGeneration += 1 // cancel any pending debounce
            writeThrottle.didFullFlush()
            return (_meta, scroll.replay)
        }
        env.store.update(meta, scrollback: bytes)
        if notify { emitMetaChange(meta) }
    }
}

/// `@unchecked Sendable` one-shot boolean, written in a pty-write completion and
/// read after the paste-delivery semaphore is signalled. The semaphore
/// signal→wait pair establishes the happens-before ordering, so the plain field
/// needs no lock of its own.
final class FlagBox: @unchecked Sendable {
    var value = false
    init() {}
}

/// `@unchecked Sendable`: a one-shot, lock-guarded slot for a subscriber cancel
/// handle, so a `@Sendable` listener can detach itself (in `autoSubmit` and in
/// the registry's accept-all flip) without capturing a mutable `var` across
/// concurrency domains. All access to the underlying optional goes through the
/// `NSLock`.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: Session.Cancel?

    init() {}

    func set(_ handle: @escaping Session.Cancel) {
        lock.withLock { self.handle = handle }
    }

    func cancel() {
        let h = lock.withLock { () -> Session.Cancel? in
            let h = handle
            handle = nil
            return h
        }
        h?()
    }
}
