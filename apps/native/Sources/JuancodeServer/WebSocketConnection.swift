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
    /// True while the writer task can't drain the socket — the coalescer and the
    /// screen streamers both hold off emitting while this reports backpressure.
    private let isBackedUp: @Sendable () -> Bool
    /// Coalesces + bounds this connection's server→client output stream
    /// (juancode-5qw.7): one frame per session per tick, dropping-and-resyncing
    /// past its byte cap so a stalled client can't exhaust server memory.
    private let outputCoalescer: ServerOutputCoalescer

    /// Stable id for this connection, used as its grid-ownership token so a
    /// session's shared pty grid has a single controlling client instead of
    /// flapping last-write-wins between viewers (juancode-1th.1).
    private let clientId = UUID().uuidString

    private let lock = NSLock()
    private var subscriptions: [String: () -> Void] = [:]
    private var activityWatchers: [() -> Void] = []
    /// Message-queue subscriptions, one per session this tab is watching
    /// (oracle-cj3 / juancode-r82). The queue itself persists; only the fan-out is
    /// torn down here.
    private var queueWatchers: [String: () -> Void] = [:]
    /// Rendered-screen streams this connection opted into (juancode-a2h.3), one
    /// per session; the stored closure tears the streamer + its exit watcher down.
    private var screenStreams: [String: () -> Void] = [:]
    private var openedEditors: Set<String> = []
    private var openedTerminals: Set<String> = []
    /// Cancel handle for this tab's tracked-PR subscription (juancode-bt2), set when
    /// the client sends `subscribeTrackedPrs`.
    private var trackedPrsUnsub: (@Sendable () -> Void)?
    /// Previous activity per session, to spot the settle edge (busy → non-busy
    /// with notify) that attaches the change rollup to the broadcast.
    private var lastActivity: [String: SessionActivity] = [:]
    /// Tail of each session's ordered activity-send chain: the settle edge shells
    /// out to git before sending, so every send awaits its predecessor to keep
    /// per-session activity ordering intact on the wire.
    private var activityChains: [String: Task<Void, Never>] = [:]

    init(state: AppState, gate: WSSendGate) {
        self.state = state
        self.send = { msg in gate.send(msg) }
        self.isBackedUp = { [weak gate] in gate?.backedUp ?? false }
        self.outputCoalescer = ServerOutputCoalescer(
            isBackedUp: { [weak gate] in gate?.backedUp ?? false },
            emitOutput: { [weak gate] id, bytes in
                gate?.send(.output(sessionId: id, data: String(decoding: bytes, as: UTF8.self)))
            })
        // Repaint an overflowed session from fresh scrollback (reuses `attached`,
        // so no new wire message). Set here — needs the fully-initialised self.
        outputCoalescer.onResync = { [weak self] id in self?.resync(id) }
    }

    /// Stop the output coalescer's timers and drop its buffer — called on teardown.
    func stopOutput() { outputCoalescer.stop() }

    // MARK: - lifecycle

    /// Begin broadcasting activity for every live session (and future ones), so
    /// the sidebar shows a status icon per session — independent of output subs.
    func start() {
        for s in state.registry.all() { watchActivity(s) }
        let off = state.registry.onCreate { [weak self] s in self?.watchActivity(s) }
        lock.withLock { activityWatchers.append(off) }
    }

    func close() {
        let (subs, watchers, queues, screens, eds, terms, prsUnsub):
            ([() -> Void], [() -> Void], [() -> Void], [() -> Void], Set<String>, Set<String>, (@Sendable () -> Void)?) =
            lock.withLock {
                let r = (Array(subscriptions.values), activityWatchers, Array(queueWatchers.values),
                         Array(screenStreams.values), openedEditors, openedTerminals, trackedPrsUnsub)
                subscriptions.removeAll(); activityWatchers.removeAll(); queueWatchers.removeAll()
                screenStreams.removeAll()
                openedEditors.removeAll(); openedTerminals.removeAll()
                trackedPrsUnsub = nil
                lastActivity.removeAll(); activityChains.removeAll()
                return r
            }
        // Release any session grids this client controlled so ownership falls to
        // the next active viewer's last-known grid (juancode-1th.1). Cheap no-op
        // for sessions it didn't own.
        for s in state.registry.all() { s.releaseGrid(owner: clientId) }
        for c in subs { c() }
        for w in watchers { w() }
        for q in queues { q() }
        for s in screens { s() }
        prsUnsub?()
        // Editor + shell ptys are tab-scoped — tear them down with the connection.
        for id in eds { state.ephemeral.get(id)?.kill() }
        for id in terms { state.ephemeral.get(id)?.kill() }
    }

    // MARK: - subscriptions

    private func watchActivity(_ s: Session) {
        // Editor sessions aren't agent turns; broadcasting their screen churn would
        // ping the oracle/Telegram bridge for a "finished" turn that never happened.
        guard s.meta.kind == .agent else { return }
        lock.withLock { lastActivity[s.id] = s.activity }
        send(.activity(sessionId: s.id, state: s.activity, notify: false, changes: nil))
        let off = s.onActivity { [weak self] st, notify in
            self?.broadcastActivity(s, state: st, notify: notify)
        }
        lock.withLock { activityWatchers.append(off) }
    }

    /// Send one activity event, attaching the whole-tree change rollup on the
    /// settle edge — the same busy → non-busy moment the desktop badge computes
    /// its ChangeStat, so the remote path can badge "finished, N files changed"
    /// too. The rollup shells out to git asynchronously, so sends chain FIFO per
    /// session: a state flip landing while a settle's diff is still computing
    /// waits behind it rather than overtaking it on the wire.
    private func broadcastActivity(_ s: Session, state: SessionActivity, notify: Bool) {
        let cwd = s.meta.cwd
        lock.withLock {
            let settled = shouldComputeChangeBadge(prev: lastActivity[s.id], next: state,
                                                   notify: notify, isEditor: false)
            lastActivity[s.id] = state
            let prevTask = activityChains[s.id]
            activityChains[s.id] = Task { [weak self] in
                await prevTask?.value
                var changes: ChangeStat?
                if settled {
                    let stat = await computeChangeStat(cwd)
                    if !stat.isEmpty { changes = stat }
                }
                self?.send(.activity(sessionId: s.id, state: state, notify: notify, changes: changes))
            }
        }
    }

    private func resolvePty(_ id: String) -> PtyLike? {
        state.registry.get(id) ?? state.ephemeral.get(id)
    }

    private func subscribe(_ id: String) {
        if lock.withLock({ subscriptions[id] != nil }) { return }
        guard let pty = resolvePty(id) else { return }
        let offOut = pty.subscribeBytes { [weak self] bytes in
            self?.outputCoalescer.append(id, bytes)
        }
        let offExit = pty.onExitHandler { [weak self] code in
            // Flush any buffered output for this session first, so the client sees
            // it before the exit rather than after (juancode-5qw.7).
            self?.outputCoalescer.flushSession(id)
            self?.send(.exit(sessionId: id, exitCode: code))
        }
        lock.withLock { subscriptions[id] = { [weak self] in offOut(); offExit(); self?.outputCoalescer.forget(id) } }
    }

    private func unsubscribe(_ id: String) {
        lock.withLock { subscriptions.removeValue(forKey: id) }?()
    }

    /// Repaint an overflowed session (its incremental output was dropped to keep
    /// the buffer bounded) by re-sending `attached` with current scrollback. Live
    /// sessions only — ephemeral editor/terminal ptys have no scrollback to replay,
    /// so a stalled one simply drops the missed bytes.
    private func resync(_ id: String) {
        guard let live = state.registry.get(id) else { return }
        send(.attached(sessionId: id,
                       scrollback: String(decoding: live.getScrollback(), as: UTF8.self),
                       session: live.meta))
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

    // MARK: - rendered-screen stream (juancode-a2h.3)

    /// Start streaming a live session's rendered screen: a full snapshot now, then
    /// coalesced row-diffs from the model's damage stream. Idempotent per session.
    /// Deliberately never touches the grid arbiter — a screen viewer is read-only
    /// and renders at the pty's own grid, so it can't steal or flap the desktop's
    /// grid. Live sessions only: the model dies with the pty, and a screen client
    /// reconnecting to a dead session should fall back to `attach`.
    private func subscribeScreen(_ id: String) {
        if lock.withLock({ screenStreams[id] != nil }) { return }
        guard let live = state.registry.get(id) else {
            send(.error(sessionId: id, message: "Session is not running")); return
        }
        let streamer = ScreenStreamer(
            sessionId: id, model: live.terminalModel,
            isBackedUp: isBackedUp,
            send: send)
        let offExit = live.onExit { [weak self, weak streamer] code in
            // Paint the final screen before the exit lands, mirroring the byte
            // path's flush-before-exit ordering.
            streamer?.flushTick()
            guard let self else { return }
            // The byte-path subscription already reports this exit — don't double up.
            if self.lock.withLock({ self.subscriptions[id] == nil && self.screenStreams[id] != nil }) {
                self.send(.exit(sessionId: id, exitCode: code))
            }
        }
        lock.withLock { screenStreams[id] = { streamer.stop(); offExit() } }
        streamer.start()
    }

    private func unsubscribeScreen(_ id: String) {
        lock.withLock { screenStreams.removeValue(forKey: id) }?()
    }

    // MARK: - message routing (mirrors ws.ts handle())

    func handle(_ msg: ClientMessage) async {
        switch msg {
        case let .create(provider, cwd, cols, rows, initialInput, skipPermissions, isolateWorktree, dispatchId):
            // A dispatch-flavored create (sidecar WS-first path) claims its id up
            // front so the same dispatch arriving via the mailbox fallback is
            // skipped — and vice versa (juancode-2kz.1). Its outcome is also
            // recorded durably so the sidecar can relay a real success/error.
            if let dispatchId, !OracleDispatchLedger.shared.claim(dispatchId) {
                send(.error(sessionId: nil, message: "Dispatch \(dispatchId) was already processed"))
                return
            }
            let recordResult: (String?, String?) -> Void = { sessionId, error in
                guard let dispatchId else { return }
                try? appendOracleDispatchResult(OracleDispatchResult(
                    dispatchId: dispatchId, project: cwd, ok: error == nil,
                    sessionId: sessionId, error: error, at: Int(Date().timeIntervalSince1970 * 1000)))
            }
            guard let pid = ProviderId(rawValue: provider) else {
                recordResult(nil, "Unknown provider: \(provider)")
                send(.error(sessionId: nil, message: "Unknown provider: \(provider)")); return
            }
            // Guard the target path with a clear error instead of a doomed spawn —
            // and, for a dispatch, a durable rejection the caller actually sees.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                let message = "\"\(cwd)\" is not an existing directory"
                recordResult(nil, message)
                send(.error(sessionId: nil, message: message)); return
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
                // The creating client controls the grid it just spawned the
                // session at, so claim ownership up front (juancode-1th.1).
                _ = session.resizeGrid(owner: clientId, cols: cols, rows: rows)
                recordResult(session.id, nil)
                send(.created(session: session.meta))
                subscribe(session.id)
                send(.attached(sessionId: session.id, scrollback: "", session: session.meta))
            } catch {
                recordResult(nil, "Failed to start \(provider): \(errMsg(error))")
                send(.error(sessionId: nil, message: "Failed to start \(provider): \(errMsg(error))"))
            }

        case let .attach(sessionId, cols, rows):
            if let live = state.registry.get(sessionId) {
                // Arbitrated: a bare attach from a secondary viewer must NOT
                // resize the pty — only the controlling owner's grid takes
                // (juancode-1th.1).
                _ = live.resizeGrid(owner: clientId, cols: cols, rows: rows)
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
            switch await reviveSession(sessionId, registry: state.registry, store: state.store,
                                       cols: cols, rows: rows) {
            case let .success(revival):
                // `attached` is truthful for both outcomes — the session is live and
                // the client is on it; a fresh boot's meta carries its new pinned id.
                let session = revival.session
                subscribe(session.id)
                send(.attached(sessionId: session.id,
                               scrollback: String(decoding: session.getScrollback(), as: UTF8.self),
                               session: session.meta))
            case .failure(.unresumable):
                send(.unresumable(sessionId: sessionId, reason: ReviveFailure.unresumable.message))
            case let .failure(failure):
                send(.error(sessionId: sessionId, message: failure.message))
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
            if let pty = resolvePty(sessionId) {
                pty.write(Array(data.utf8))
            } else {
                // The session process is gone — revive-then-deliver instead of
                // silently dropping a remote message (juancode-23m).
                await reviveForRemoteMessage(sessionId, data: data)
            }
            // Acknowledge sequenced input so the client can clear it from its
            // unacked buffer (juancode-1u3). Acked after the write attempt
            // regardless of whether the pty still exists — the ack means the
            // server received and processed the frame; a dead pty surfaces via
            // its own `exit`.
            if let seq { send(.inputAck(sessionId: sessionId, seq: seq)) }

        case let .resize(sessionId, cols, rows, seq):
            // Sessions arbitrate the shared grid per client (juancode-1th.1): a
            // non-owner's resize is `denied` and left un-applied so the CLI TUI
            // can't flap between two viewers' sizes. Ephemeral editor/terminal
            // ptys are tab-scoped (single owner), so they resize unarbitrated.
            // Either way `applied` reports whether the grid reached a live pty — a
            // resize that races session spawn is dropped (applied:false, not
            // denied), so a sequenced client re-asserts it (juancode-uz6).
            let applied: Bool
            var denied = false
            if let session = state.registry.get(sessionId) {
                (applied, denied) = session.resizeGrid(owner: clientId, cols: cols, rows: rows)
            } else {
                applied = state.ephemeral.get(sessionId)?.resize(cols: cols, rows: rows) ?? false
            }
            if let seq {
                send(.resizeAck(sessionId: sessionId, seq: seq, cols: cols, rows: rows,
                                applied: applied, denied: denied))
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
            if let live = state.registry.get(sessionId) {
                live.kickQueue()
            } else {
                // Dead session: revive it so the queued message can land — the
                // boot's busy→idle edge flushes the queue (juancode-23m). The
                // message stays persisted in the queue either way; a failed
                // revival is surfaced instead of leaving it silently pending.
                if case let .failure(failure) = await reviveSession(
                    sessionId, registry: state.registry, store: state.store) {
                    send(.error(sessionId: sessionId, message: failure.message))
                }
            }

        case let .dequeueMessage(sessionId, messageId):
            state.messageQueue.remove(sessionId, messageId)

        // ── Rendered-screen stream (juancode-a2h.3) ────────────────────────────────
        case let .subscribeScreen(sessionId):
            subscribeScreen(sessionId)

        case let .unsubscribeScreen(sessionId):
            unsubscribeScreen(sessionId)

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

    // MARK: - revive-then-deliver for dead sessions (juancode-23m)

    /// Handle `input` addressed to a session whose process is gone.
    ///
    /// Only *message-like* input revives: one complete bracketed paste per frame,
    /// which is exactly how the oracle sidecar delivers a Telegram/phone reply
    /// (`deliverReply` in oracle.ts). The text lands via `autoSubmit`, which waits
    /// for the resumed TUI's input box before pasting + submitting — a raw `write`
    /// into a booting CLI gets swallowed. Raw keystrokes to a dead session stay
    /// silently dropped, as before: reviving per keystroke would spawn a revival
    /// storm, and an error per byte would spam interactive clients — those gate
    /// typing on the live pty and reactivate explicitly. A failed revival is
    /// surfaced as an `error` frame instead of vanishing.
    private func reviveForRemoteMessage(_ sessionId: String, data: String) async {
        guard let text = bracketedPasteMessage(data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch await reviveSession(sessionId, registry: state.registry, store: state.store) {
        case let .success(revival):
            revival.session.autoSubmit(text)
        case let .failure(failure):
            send(.error(sessionId: sessionId, message: failure.message))
        }
    }
}

/// If a remote `input` frame is one complete bracketed paste (`ESC[200~ … ESC[201~`,
/// optionally followed by a submitting CR/LF), return the pasted text — the exact
/// shape the oracle sidecar's reply path sends. Anything else (raw keystrokes,
/// partial pastes, several pastes in one frame) returns nil.
func bracketedPasteMessage(_ data: String) -> String? {
    let start = "\u{1B}[200~", end = "\u{1B}[201~"
    guard data.hasPrefix(start) else { return nil }
    var rest = String(data.dropFirst(start.count))
    // "\r\n" is one grapheme in Swift, so check it explicitly alongside lone CR/LF.
    while rest.hasSuffix("\r\n") || rest.hasSuffix("\r") || rest.hasSuffix("\n") { rest.removeLast() }
    guard rest.hasSuffix(end) else { return nil }
    let body = String(rest.dropLast(end.count))
    guard !body.contains(start), !body.contains(end) else { return nil }
    return body
}
