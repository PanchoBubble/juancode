import Foundation
import JuancodeCore
import JuancodeServices

/// Common surface over a real `Session` and an ephemeral editor/shell `Pty`, so
/// the WS layer addresses both by id over the same input/resize/kill/output/exit
/// messages (mirrors `resolvePty` in ws.ts).
protocol PtyLike: AnyObject {
    func write(_ bytes: [UInt8])
    @discardableResult func resize(cols: Int, rows: Int) -> Bool
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
    /// Message-queue subscriptions, one per session this tab is watching
    /// (oracle-cj3 / juancode-r82). The queue itself persists; only the fan-out is
    /// torn down here.
    private var queueWatchers: [String: () -> Void] = [:]
    private var openedEditors: Set<String> = []
    private var openedTerminals: Set<String> = []
    /// Cancel handle for this tab's tracked-PR subscription (juancode-bt2), set when
    /// the client sends `subscribeTrackedPrs`.
    private var trackedPrsUnsub: (@Sendable () -> Void)?

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
        let (subs, watchers, queues, eds, terms, prsUnsub):
            ([() -> Void], [() -> Void], [() -> Void], Set<String>, Set<String>, (@Sendable () -> Void)?) =
            lock.withLock {
                let r = (Array(subscriptions.values), activityWatchers, Array(queueWatchers.values),
                         openedEditors, openedTerminals, trackedPrsUnsub)
                subscriptions.removeAll(); activityWatchers.removeAll(); queueWatchers.removeAll()
                openedEditors.removeAll(); openedTerminals.removeAll()
                trackedPrsUnsub = nil
                return r
            }
        for c in subs { c() }
        for w in watchers { w() }
        for q in queues { q() }
        prsUnsub?()
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

    // MARK: - message-queue fan-out (oracle-cj3 / juancode-r82)

    /// Push the current queue snapshot, then a fresh snapshot on every change, until
    /// `unsubscribeQueue` or the connection closes. Idempotent per session.
    private func subscribeQueue(_ id: String) {
        if lock.withLock({ queueWatchers[id] != nil }) { return }
        send(.queue(sessionId: id, items: state.messageQueue.list(id)))
        let off = state.messageQueue.onChange(id) { [weak self] items in
            self?.send(.queue(sessionId: id, items: items))
        }
        lock.withLock { queueWatchers[id] = off }
    }

    private func unsubscribeQueue(_ id: String) {
        lock.withLock { queueWatchers.removeValue(forKey: id) }?()
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

        case let .adoptExternal(provider, cliSessionId, cwd, startMs, cols, rows):
            guard let pid = ProviderId(rawValue: provider) else {
                send(.error(sessionId: nil, message: "Unknown provider: \(provider)")); return
            }
            // We already own this conversation — don't adopt it twice.
            guard !state.store.usedCliSessionIds().contains(cliSessionId) else { return }
            let meta = SessionMeta.adopting(provider: pid, cliSessionId: cliSessionId,
                                            cwd: cwd, startMs: startMs)
            state.store.insert(meta)
            do {
                // Empty prior scrollback: the CLI reprints its own context on resume.
                let session = try state.registry.resume(meta, cols: cols, rows: rows, priorScrollback: [])
                send(.created(session: session.meta))
                subscribe(session.id)
                send(.attached(sessionId: session.id,
                               scrollback: String(decoding: session.getScrollback(), as: UTF8.self),
                               session: session.meta))
            } catch {
                send(.error(sessionId: meta.id, message: "Failed to resume: \(errMsg(error))"))
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

        case let .input(sessionId, data, seq):
            resolvePty(sessionId)?.write(Array(data.utf8))
            // Acknowledge sequenced input so the client can clear it from its
            // unacked buffer (juancode-1u3). Acked after the write attempt
            // regardless of whether the pty still exists — the ack means the
            // server received and processed the frame; a dead pty surfaces via
            // its own `exit`.
            if let seq { send(.inputAck(sessionId: sessionId, seq: seq)) }

        case let .resize(sessionId, cols, rows, seq):
            // `resize` returns whether the grid reached a live pty; a resize that
            // arrives before the pty is running is dropped. Ack that outcome so a
            // sequenced client can re-assert instead of trusting a grid that never
            // landed (juancode-uz6). No pty at all → not applied.
            let applied = resolvePty(sessionId)?.resize(cols: cols, rows: rows) ?? false
            if let seq {
                send(.resizeAck(sessionId: sessionId, seq: seq, cols: cols, rows: rows, applied: applied))
            }

        case let .kill(sessionId):
            resolvePty(sessionId)?.kill()

        // ── Per-session message queue (oracle-cj3 / juancode-r82) ─────────────────
        case let .subscribeQueue(sessionId):
            subscribeQueue(sessionId)

        case let .unsubscribeQueue(sessionId):
            unsubscribeQueue(sessionId)

        case let .queueMessage(sessionId, text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            state.messageQueue.add(sessionId, text: trimmed)
            // Deliver right away if the session is already idle; otherwise it
            // flushes on the next idle edge.
            state.registry.get(sessionId)?.kickQueue()

        case let .dequeueMessage(sessionId, messageId):
            state.messageQueue.remove(sessionId, messageId)

        // ── Tracked-PR registry (juancode-bt2) ───────────────────────────────────
        case .subscribeTrackedPrs:
            // Idempotent: a tab subscribes once. Fan the engine's changes through
            // `send`, mapped to the wire ServerMessages. The engine hands us the
            // current snapshot synchronously on subscribe.
            if lock.withLock({ trackedPrsUnsub != nil }) { return }
            let off = await state.prTracking.subscribe { [weak self] change in
                switch change {
                case let .tracked(list):
                    self?.send(.trackedPrs(tracked: list))
                case let .notification(trackedId, prNumber, notification):
                    self?.send(.trackNotification(trackedId: trackedId, prNumber: prNumber,
                                                  notification: notification))
                }
            }
            lock.withLock { trackedPrsUnsub = off }

        case let .trackPr(cwd, pr):
            await state.prTracking.track(pr, cwd: cwd)

        case let .untrackPr(trackedId):
            await state.prTracking.untrack(trackedId)

        case let .resolveTrackNotification(trackedId, notificationId):
            await state.prTracking.resolveNotification(trackedId: trackedId, notificationId: notificationId)

        case .unknown:
            // A well-formed message this server doesn't implement (e.g. a TS-only
            // type like `subscribeStructured`/`steerMessage`, or a newer client
            // feature). Ignore it — clients feature-detect via `serverInfo`
            // capabilities, so this is just belt-and-braces (juancode-tgc).
            break
        }
    }
}
