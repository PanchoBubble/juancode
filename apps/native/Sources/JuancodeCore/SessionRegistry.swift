import Foundation

/// Holds the live (in-memory) ptys for the current process lifetime. Mirrors
/// `apps/server/src/registry.ts`. The local SwiftUI view and remote WS clients
/// are both just subscribers to sessions tracked here.
/// `@unchecked Sendable`: the mutable `sessions` / `createListeners` maps and
/// `nextToken` are only ever touched under `lock` (an `NSRecursiveLock`); `env`
/// is `let`. That lock is the synchronization invariant, so the registry is safe
/// to share across the spawning thread, session exit callbacks, and WS handlers.
public final class SessionRegistry: @unchecked Sendable {
    public typealias CreateListener = (Session) -> Void

    private let lock = NSRecursiveLock()
    private var sessions: [String: Session] = [:]
    private var createListeners: [Int: CreateListener] = [:]
    private var nextToken = 0
    private let env: SessionEnvironment

    public init(env: SessionEnvironment = SessionEnvironment()) {
        self.env = env
    }

    @discardableResult
    public func create(
        provider: ProviderId,
        cwd: String,
        cols: Int,
        rows: Int,
        opts: SpawnOptions = SpawnOptions(),
        worktreePath: String? = nil
    ) throws -> Session {
        try track(Session.create(
            provider: provider, cwd: cwd, cols: cols, rows: rows,
            opts: opts, worktreePath: worktreePath, env: env
        ))
    }

    /// Revive an exited session by resuming its prior CLI conversation.
    @discardableResult
    public func resume(
        _ prev: SessionMeta,
        cols: Int,
        rows: Int,
        priorScrollback: [UInt8] = []
    ) throws -> Session {
        try track(Session.resume(prev, cols: cols, rows: rows,
                                 priorScrollback: priorScrollback, env: env))
    }

    /// Flip "accept all" on a live session. There's no way to change a running
    /// CLI's permission flag in place, so we kill the pty and resume the same
    /// conversation (keeping the juancode id + scrollback) with the new level.
    /// Resolves once the old pty has exited and the new one is up.
    public func setSkipPermissions(
        _ sessionId: String,
        skipPermissions: Bool,
        cols: Int,
        rows: Int
    ) async throws -> Session {
        guard let live = get(sessionId) else { throw SessionError.notRunning }
        if live.meta.skipPermissions == skipPermissions { return live }
        guard live.meta.cliSessionId != nil else { throw SessionError.notResumable }

        var nextMeta = live.meta
        nextMeta.skipPermissions = skipPermissions
        let next = nextMeta // immutable copy for the `@Sendable` exit closure

        // Snapshot scrollback now so the revived pty carries the conversation
        // forward, with a marker before the resumed CLI repaints over it.
        let prior = env.store.getScrollback(sessionId) ?? live.getScrollback()
        let marker = "\r\n\u{1B}[2m── accept-all \(skipPermissions ? "enabled" : "disabled") ──\u{1B}[0m\r\n"
        let seed = prior.isEmpty ? [] : prior + Array(marker.utf8)

        return try await withCheckedThrowingContinuation { cont in
            // Resume only after the old pty is fully gone, so its exit cleanup
            // (which drops the id from the live map) can't clobber the revived one.
            // The cancel handle is held in a Sendable box so the `@Sendable` exit
            // listener can detach itself without capturing a mutable `var`.
            let off = CancelBox()
            off.set(live.onExit { [weak self] _ in
                off.cancel()
                guard let self else { return }
                do {
                    cont.resume(returning: try self.resume(next, cols: cols, rows: rows, priorScrollback: seed))
                } catch {
                    cont.resume(throwing: error)
                }
            })
            live.kill()
        }
    }

    @discardableResult
    private func track(_ session: Session) -> Session {
        lock.withLock { sessions[session.id] = session }
        session.onExit { [weak self, weak session] _ in
            guard let self, let session else { return }
            // Drop it from the live map so it isn't treated as attachable. The
            // Session object lives on as long as a subscriber holds it, so late
            // listeners still get the exit.
            self.lock.withLock { _ = self.sessions.removeValue(forKey: session.id) }
        }
        for l in lock.withLock({ Array(createListeners.values) }) { l(session) }
        return session
    }

    public func get(_ id: String) -> Session? {
        lock.withLock { sessions[id] }
    }

    /// Every currently live session.
    public func all() -> [Session] {
        lock.withLock { Array(sessions.values) }
    }

    /// Notify when any session is created or resumed (live again). Returns a
    /// cancel handle.
    @discardableResult
    public func onCreate(_ listener: @escaping CreateListener) -> () -> Void {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            createListeners[t] = listener
            return t
        }
        return { [weak self] in self?.lock.withLock { _ = self?.createListeners.removeValue(forKey: token) } }
    }

    public func killAll() {
        for s in all() { s.kill() }
    }
}
