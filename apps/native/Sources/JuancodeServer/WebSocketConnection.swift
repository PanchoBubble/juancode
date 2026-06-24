import Foundation
import JuancodeCore
import JuancodeServices

/// Common surface over a real `Session` and an ephemeral editor/shell `Pty`, so
/// the WS layer addresses both by id over the same input/resize/kill/output/exit
/// messages (mirrors `resolvePty` in ws.ts).
protocol PtyLike: AnyObject {
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func kill()
    @discardableResult func subscribeBytes(_ onBytes: @escaping @Sendable ([UInt8]) -> Void) -> () -> Void
    @discardableResult func onExitHandler(_ cb: @escaping @Sendable (Int?) -> Void) -> () -> Void
}

extension Session: PtyLike {
    // The 'attached' message carries scrollback explicitly, so the live stream
    // subscription does NOT replay (matches `session.onOutput` in ws.ts).
    func subscribeBytes(_ onBytes: @escaping @Sendable ([UInt8]) -> Void) -> () -> Void {
        subscribeOutput(replay: false, onBytes)
    }
    func onExitHandler(_ cb: @escaping @Sendable (Int?) -> Void) -> () -> Void { onExit(cb) }
}

extension EphemeralPty: PtyLike {
    func subscribeBytes(_ onBytes: @escaping @Sendable ([UInt8]) -> Void) -> () -> Void { onOutput(onBytes) }
    func onExitHandler(_ cb: @escaping @Sendable (Int?) -> Void) -> () -> Void { onExit(cb) }
}

/// One browser/phone WebSocket connection. A faithful port of the per-connection
/// closure in `ws.ts`: tracks this tab's output subscriptions + activity
/// watchers, routes client messages, and tears everything down on disconnect
/// (including tab-scoped editor/terminal ptys, which never outlive the tab).
final class WebSocketConnection: @unchecked Sendable {
    private let state: AppState
    /// Enqueue a server message for the writer task (thread-safe).
    let send: @Sendable (ServerMessage) -> Void

    private let lock = NSLock()
    private var subscriptions: [String: () -> Void] = [:]
    private var activityWatchers: [() -> Void] = []
    private var openedEditors: Set<String> = []
    private var openedTerminals: Set<String> = []

    init(state: AppState, send: @escaping @Sendable (ServerMessage) -> Void) {
        self.state = state
        self.send = send
    }

    // MARK: - lifecycle

    /// Begin broadcasting activity for every live session (and future ones), so
    /// the sidebar shows a status icon per session — independent of output subs.
    func start() {
        for s in state.registry.all() { watchActivity(s) }
        let off = state.registry.onCreate { [weak self] s in self?.watchActivity(s) }
        lock.withLock { activityWatchers.append(off) }
    }

    func close() {
        let (subs, watchers, eds, terms): ([() -> Void], [() -> Void], Set<String>, Set<String>) =
            lock.withLock {
                let r = (Array(subscriptions.values), activityWatchers, openedEditors, openedTerminals)
                subscriptions.removeAll(); activityWatchers.removeAll()
                openedEditors.removeAll(); openedTerminals.removeAll()
                return r
            }
        for c in subs { c() }
        for w in watchers { w() }
        // Editor + shell ptys are tab-scoped — tear them down with the connection.
        for id in eds { state.ephemeral.get(id)?.kill() }
        for id in terms { state.ephemeral.get(id)?.kill() }
    }

    // MARK: - subscriptions

    private func watchActivity(_ s: Session) {
        send(.activity(sessionId: s.id, state: s.activity, notify: false))
        let off = s.onActivity { [weak self] st, notify in
            self?.send(.activity(sessionId: s.id, state: st, notify: notify))
        }
        lock.withLock { activityWatchers.append(off) }
    }

    private func resolvePty(_ id: String) -> PtyLike? {
        state.registry.get(id) ?? state.ephemeral.get(id)
    }

    private func subscribe(_ id: String) {
        if lock.withLock({ subscriptions[id] != nil }) { return }
        guard let pty = resolvePty(id) else { return }
        let offOut = pty.subscribeBytes { [weak self] bytes in
            self?.send(.output(sessionId: id, data: String(decoding: bytes, as: UTF8.self)))
        }
        let offExit = pty.onExitHandler { [weak self] code in
            self?.send(.exit(sessionId: id, exitCode: code))
        }
        lock.withLock { subscriptions[id] = { offOut(); offExit() } }
    }

    private func unsubscribe(_ id: String) {
        lock.withLock { subscriptions.removeValue(forKey: id) }?()
    }

    // MARK: - message routing (mirrors ws.ts handle())

    func handle(_ msg: ClientMessage) async {
        switch msg {
        case let .create(provider, cwd, cols, rows, initialInput, skipPermissions, isolateWorktree):
            guard let pid = ProviderId(rawValue: provider) else {
                send(.error(sessionId: nil, message: "Unknown provider: \(provider)")); return
            }
            do {
                // Opt-in isolation: a fresh worktree off cwd so the session can't
                // clobber other sessions' working tree.
                var workCwd = cwd
                var worktreePath: String? = nil
                if isolateWorktree == true {
                    let wt = try await createWorktree(cwd, String(UUID().uuidString.prefix(8)).lowercased())
                    workCwd = wt.path
                    worktreePath = wt.path
                }
                let session = try state.registry.create(
                    provider: pid, cwd: workCwd, cols: cols, rows: rows,
                    opts: SpawnOptions(skipPermissions: skipPermissions ?? false),
                    worktreePath: worktreePath
                )
                if let initialInput, !initialInput.isEmpty { session.autoSubmit(initialInput) }
                send(.created(session: session.meta))
                subscribe(session.id)
                send(.attached(sessionId: session.id, scrollback: "", session: session.meta))
            } catch {
                send(.error(sessionId: nil, message: "Failed to start \(provider): \(errMsg(error))"))
            }

        case let .attach(sessionId, cols, rows):
            if let live = state.registry.get(sessionId) {
                live.resize(cols: cols, rows: rows)
                subscribe(sessionId)
                send(.attached(sessionId: sessionId,
                               scrollback: String(decoding: live.getScrollback(), as: UTF8.self),
                               session: live.meta))
                return
            }
            guard let meta = state.store.get(sessionId) else {
                send(.error(sessionId: sessionId, message: "Session not found")); return
            }
            let scroll = String(decoding: state.store.getScrollback(sessionId) ?? [], as: UTF8.self)
            send(.attached(sessionId: sessionId, scrollback: scroll, session: meta))
            send(.exit(sessionId: sessionId, exitCode: meta.exitCode))

        case let .reactivate(sessionId, cols, rows):
            if state.registry.get(sessionId) != nil { return } // already live
            guard var meta = state.store.get(sessionId) else {
                send(.error(sessionId: sessionId, message: "Session not found")); return
            }
            // Old sessions predate id capture; try to recover it from the CLI's
            // own transcript so they can be resumed like newer ones.
            if meta.cliSessionId == nil {
                if let recovered = await recoverCliSessionId(
                    meta.provider, cwd: meta.cwd, createdAtMs: meta.createdAt,
                    excludeIds: state.store.usedCliSessionIds()
                ) {
                    state.store.setCliSessionId(meta.id, cliSessionId: recovered)
                    meta.cliSessionId = recovered
                }
            }
            guard meta.cliSessionId != nil else {
                send(.unresumable(sessionId: sessionId,
                                  reason: "No prior CLI conversation could be found to resume this session."))
                return
            }
            do {
                // Carry persisted scrollback into the revived session (with a
                // separator before the CLI repaints its TUI underneath).
                let prior = state.store.getScrollback(meta.id) ?? []
                let seed: [UInt8] = prior.isEmpty
                    ? []
                    : prior + Array("\r\n\u{1B}[2m── session resumed ──\u{1B}[0m\r\n".utf8)
                let session = try state.registry.resume(meta, cols: cols, rows: rows, priorScrollback: seed)
                subscribe(session.id)
                send(.attached(sessionId: session.id,
                               scrollback: String(decoding: session.getScrollback(), as: UTF8.self),
                               session: session.meta))
            } catch {
                send(.error(sessionId: sessionId, message: "Failed to resume: \(errMsg(error))"))
            }

        case let .setSkipPermissions(sessionId, skip, cols, rows):
            guard state.registry.get(sessionId) != nil else {
                send(.error(sessionId: sessionId, message: "Session is not running")); return
            }
            // Drop the subscription before the resume-restart so the client doesn't
            // observe the transient exit of the old pty.
            unsubscribe(sessionId)
            do {
                let session = try await state.registry.setSkipPermissions(
                    sessionId, skipPermissions: skip, cols: cols, rows: rows)
                subscribe(session.id)
                send(.attached(sessionId: session.id,
                               scrollback: String(decoding: session.getScrollback(), as: UTF8.self),
                               session: session.meta))
            } catch {
                // Flip failed before killing the pty — re-subscribe to the still-live one.
                subscribe(sessionId)
                send(.error(sessionId: sessionId, message: "Failed to change permissions: \(errMsg(error))"))
            }

        case let .openEditor(cwd, file, cols, rows):
            do {
                let ed = try state.ephemeral.openEditor(cwd: cwd, file: file, cols: cols, rows: rows)
                lock.withLock { _ = openedEditors.insert(ed.id) }
                subscribe(ed.id)
                send(.editorReady(editorId: ed.id))
            } catch {
                send(.error(sessionId: nil, message: "Failed to open editor: \(errMsg(error))"))
            }

        case let .openTerminal(cwd, cols, rows, requestId):
            do {
                let sh = try state.ephemeral.openTerminal(cwd: cwd, cols: cols, rows: rows)
                lock.withLock { _ = openedTerminals.insert(sh.id) }
                subscribe(sh.id)
                send(.terminalReady(terminalId: sh.id, requestId: requestId))
            } catch {
                send(.error(sessionId: nil, message: "Failed to open terminal: \(errMsg(error))"))
            }

        case let .input(sessionId, data):
            resolvePty(sessionId)?.write(Array(data.utf8))

        case let .resize(sessionId, cols, rows):
            resolvePty(sessionId)?.resize(cols: cols, rows: rows)

        case let .kill(sessionId):
            resolvePty(sessionId)?.kill()
        }
    }
}
