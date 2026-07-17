import Foundation
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// Shared, process-wide state the embedded server (and the local SwiftUI shell)
/// both drive: the live session registry (owning the real ptys), the SQLite
/// store, and the ephemeral editor/terminal ptys. Mirrors the module-level
/// singletons of the Node server (`registry`, `sessionDb`, `editors`,
/// `terminals`) — but here a single owned object so the GUI can hold it too.
public final class AppState: @unchecked Sendable {
    public let store: GRDBStore
    public let registry: SessionRegistry
    public let ephemeral = EphemeralPtyRegistry()
    /// Per-session outbound message queue (oracle-cj3 / juancode-r82), persisted in
    /// the same SQLite store. The session registry's env drives it on idle edges;
    /// the WS layer reads/mutates it and fans changes to watchers.
    public let messageQueue: MessageQueue
    /// Server-side tracked-PR engine (juancode-bt2) — drives PR tracking over the
    /// wire for the remote web/phone client, mirroring the GUI's in-process tracking.
    public let prTracking: PrTrackingEngine
    /// Idle-session reaper (juancode-lgq) — kills verifiably idle CLI process
    /// trees to free RAM, leaving each session dormant and resumable on demand.
    public let sessionReaper: SessionReaper
    /// Rolling on-disk session activity log (`Config.logsDir`) — the durable
    /// lifecycle/seed/activity trail for debugging frozen sessions after the fact.
    public let activityLog: SessionActivityLog

    public init(store: GRDBStore) {
        self.store = store
        let activityLog = SessionActivityLog()
        self.activityLog = activityLog
        // The queue persists into the same store, so it survives restarts / reconnects.
        let messageQueue = MessageQueue(persistence: store)
        self.messageQueue = messageQueue
        // The registry's session env carries the real seams: login-shell binary
        // resolution, this store, the message queue, Codex id discovery, and
        // title/usage polling.
        let registry = SessionRegistry(env: .live(store: store, messageQueue: messageQueue,
                                                  log: activityLog))
        self.registry = registry
        self.prTracking = PrTrackingEngine(registry: registry, store: store, activityLog: activityLog)
        let sessionReaper = SessionReaper(registry: registry, messageQueue: messageQueue)
        self.sessionReaper = sessionReaper
        Task { await sessionReaper.start() }
        // Any session still "running" in the db is stale — its pty died with the
        // previous process. Mark them exited so the UI shows truth.
        store.markOrphansExited()
        // Enforce the per-project retention cap on the persisted history (juancode-477).
        // Nothing is live this early, so no ids need protecting.
        store.enforceSessionCap()
    }

    public convenience init(dbPath: String? = nil) throws {
        self.init(store: try GRDBStore(path: dbPath))
    }

    // MARK: - Desktop presence (juancode-2zp)
    //
    // The macOS app updates `lastActiveMs` whenever it becomes/resigns frontmost so
    // the embedded server (and, through it, the oracle-mcp push gate) can tell the
    // user is at the desk and stay quiet on the phone. Lock-guarded for the same
    // reason this whole class is `@unchecked Sendable`: the app drives it on the main
    // actor while server request handlers read it from NIO threads.
    private let presenceLock = NSLock()
    private var _lastActiveMs: Int?

    /// Mark the desktop active right now (app became frontmost). Records the wall-clock
    /// timestamp so a freshness window can later decide "frontmost".
    public func markDesktopActive() {
        presenceLock.lock()
        _lastActiveMs = nowMs()
        presenceLock.unlock()
    }

    /// Epoch-ms of the last time the desktop was frontmost, or nil if it never was
    /// since launch.
    public var desktopLastActiveMs: Int? {
        presenceLock.lock()
        defer { presenceLock.unlock() }
        return _lastActiveMs
    }

    /// Tear down every live pty (sessions + ephemeral) on shutdown.
    public func shutdown() {
        registry.killAll()
        ephemeral.killAll()
    }

    /// Graceful shutdown: request termination of every live session and *wait*
    /// (bounded by `timeout`) for each pty to actually exit before returning
    /// (juancode-6cqj). A bare `shutdown()` only fires SIGTERM and returns, so on
    /// app quit the process is torn down before the CLI flushes its transcript and
    /// before our own `handleExit -> persistNow()` runs — losing the last, unflushed
    /// turns (they're absent from the transcript `--resume` repaints from on reopen).
    /// Each `Session.handleExit` persists *before* firing its exit listener, so
    /// awaiting the exits guarantees both the CLI's transcript flush and our persist
    /// have landed. Blocks the calling thread; call it off the main actor.
    public func shutdownGracefully(timeout: TimeInterval = 3.0) {
        let live = registry.all().filter { $0.isRunning }
        guard !live.isEmpty else {
            shutdown()
            return
        }
        let group = DispatchGroup()
        var cancels: [() -> Void] = []
        for session in live {
            group.enter()
            let left = OnceFlag()
            let cancel = session.onExit { _ in if left.fire() { group.leave() } }
            cancels.append(cancel)
        }
        // Request termination now (SIGTERM / master-EOF). The real exit + persist
        // happens on each session's work queue and fires the listener above.
        for session in live { session.kill() }
        _ = group.wait(timeout: .now() + timeout)
        for cancel in cancels { cancel() }
        // Force-kill anything that didn't exit within the budget, plus ephemeral ptys.
        shutdown()
    }
}

/// One-shot latch so a (possibly re-entrant) exit listener leaves its DispatchGroup
/// exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
