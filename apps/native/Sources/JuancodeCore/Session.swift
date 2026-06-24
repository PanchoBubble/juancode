import Foundation

public enum SessionError: Error {
    case spawnFailed
    case notResumable
    case notRunning
}

/// Dependencies a `Session` needs, injected by the registry so tests can supply
/// fakes (in-memory store, fake binary resolver, stub codex discovery).
public struct SessionEnvironment: Sendable {
    public var resolver: BinaryResolver
    public var store: SessionStore
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

    public init(
        resolver: BinaryResolver = DefaultBinaryResolver(),
        store: SessionStore = InMemorySessionStore(),
        scrollbackLimit: Int = 256 * 1024,
        discoverCodexId: @escaping @Sendable (String, Int) async -> String? = {
            await CodexSessionDiscovery.capture(cwd: $0, sinceMs: $1)
        },
        deriveTitle: @escaping @Sendable (ProviderId, String) async -> String? = { _, _ in nil },
        deriveUsage: @escaping @Sendable (ProviderId, String) async -> SessionUsage? = { _, _ in nil }
    ) {
        self.resolver = resolver
        self.store = store
        self.scrollbackLimit = scrollbackLimit
        self.discoverCodexId = discoverCodexId
        self.deriveTitle = deriveTitle
        self.deriveUsage = deriveUsage
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

    private let lock = NSRecursiveLock()
    private var _meta: SessionMeta
    private let env: SessionEnvironment
    private let spec: ProviderSpec
    private var proc: PtyProcess?

    private var scroll: Scrollback
    private var outputListeners: [Int: OutputListener] = [:]
    private var exitListeners: [Int: ExitListener] = [:]
    private var activityListeners: [Int: ActivityListener] = [:]
    private var nextToken = 0

    private let workQueue: DispatchQueue
    private var detector: ActivityDetector!

    private let persistDebounceMs = 2000
    private var persistGeneration = 0

    private let titlePollMs = 4000
    private var titleTimer: DispatchSourceTimer?

    /// Set once the user renames the session manually, so the CLI-derived title
    /// poll stops clobbering their chosen name.
    private var titleIsManual = false

    public var meta: SessionMeta { lock.withLock { _meta } }
    public var id: String { lock.withLock { _meta.id } }
    public var isRunning: Bool { lock.withLock { _meta.status == .running } }
    public var activity: SessionActivity { detector.activity }

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
        meta.updatedAt = nowMs()
        let opts = SpawnOptions(skipPermissions: meta.skipPermissions)
        return try Session(meta: meta, args: spec.resumeArgs(cliSessionId, opts), cols: cols, rows: rows,
                           isNew: false, env: env, seedScrollback: priorScrollback)
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
        self.spec = Providers.spec(for: meta.provider)
        self.scroll = Scrollback(limit: env.scrollbackLimit, seed: seedScrollback)
        self.workQueue = DispatchQueue(label: "juancode.session.\(meta.id)")

        self.detector = ActivityDetector { [weak self] state, notify in
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
            env.store.update(meta, scrollback: scroll.bytes)
        }

        // For Codex we can't pin the session id, so discover it from the rollout file.
        if !spec.pinsSessionId && meta.cliSessionId == nil {
            captureCliSessionId()
        }

        // Keep the title + usage in sync with the CLI's own transcript.
        startTitleWatch()
    }

    // MARK: - pty callbacks (on workQueue)

    private func handleData(_ bytes: [UInt8]) {
        lock.withLock { scroll.append(bytes) }
        detector.feed(String(decoding: bytes, as: UTF8.self))
        for l in snapshotOutput() { l(bytes) }
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
        // One last transcript read to catch a late-generated title / final usage.
        refreshTitleAndUsage()
        persistNow()
        let listeners = lock.withLock { Array(exitListeners.values) }
        for l in listeners { l(Int(code)) }
    }

    private func emitActivity(_ state: SessionActivity, _ notify: Bool) {
        for l in lock.withLock({ Array(activityListeners.values) }) { l(state, notify) }
    }

    // MARK: - input / lifecycle

    public func write(_ bytes: [UInt8]) {
        if isRunning { proc?.write(bytes) }
    }

    public func write(_ text: String) {
        write(Array(text.utf8))
    }

    /// Type `text` and submit it once the CLI's TUI has rendered (waits for the
    /// first output so the TUI is in raw mode, then a short delay + carriage return).
    public func autoSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Hold the cancel handle in a Sendable box so the (now `@Sendable`)
        // listener can detach itself on first output without capturing a mutable
        // `var` across concurrency domains.
        let holder = CancelBox()
        holder.set(subscribeOutput(replay: false) { [weak self] _ in
            holder.cancel()
            guard let self else { return }
            self.workQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self else { return }
                self.write("\(trimmed)\r")
            }
        })
    }

    public func resize(cols: Int, rows: Int) {
        if isRunning { proc?.resize(cols: cols, rows: rows) }
    }

    public func kill() {
        stopTitleWatch()
        if isRunning { proc?.terminate() }
    }

    public func getScrollback() -> [UInt8] {
        lock.withLock { scroll.bytes }
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
            return (t, replay ? scroll.bytes : [])
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
        if changed { persistNow() }
    }

    /// Archive / unarchive the live session and persist the flag.
    public func setArchived(_ archived: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard archived != _meta.archived else { return false }
            _meta.archived = archived
            return true
        }
        if changed { persistNow() }
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
        if changed { persistNow() }
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
        if changed { persistNow() }
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
            self.persistNow()
        }
    }

    private func persistNow() {
        let (meta, bytes) = lock.withLock { () -> (SessionMeta, [UInt8]) in
            _meta.updatedAt = nowMs()
            persistGeneration += 1 // cancel any pending debounce
            return (_meta, scroll.bytes)
        }
        env.store.update(meta, scrollback: bytes)
    }
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
