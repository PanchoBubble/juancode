import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServer
import JuancodeServices

/// `CoreClient` over the `juancoded` Rust daemon: one WebSocket connection
/// speaking protocol v1, plus a desktop-side mirror of the session rows it has
/// been told about.
///
/// Two things about this class are worth reading before the code.
///
/// **It never pretends.** The daemon advertises what it implements in
/// `serverInfo.capabilities`, and today that is `inputAck`, `resizeAck`, `screen`
/// and `adoptExternal` — no `queue`, `trackedPrs`, `editor`, `terminal`,
/// `sessionMeta` or `gridOwner`. Every member backed by a capability the connected
/// core lacks either throws `CoreCapabilityError` (so a caller that got past the
/// UI gate is a visible bug) or answers empty, and the UI reads the same list to
/// grey the affordance out with the reason. Nothing here silently succeeds.
///
/// **The mirror is not the core's store.** The daemon owns its own SQLite at
/// `$JUANCODED_DATA_DIR/juancoded-rust.db` (default `~/.juancode/rust-core`) and
/// is its only writer. Protocol v1 has no "list sessions" frame — the desktop got
/// that from REST endpoints the daemon does not serve — so the sidebar, the search
/// index and the retention cap read a desktop-side mirror at
/// `<dataDir>/juancode-rust.db`, fed from `created`/`attached`/`sessionMeta`/`exit`.
/// It is deliberately a different file from the Swift core's `juancode.db`: one
/// writer per file, and no schema drift between two cores.
public final class RustCoreClient: CoreClient, RemoteSessionTransport, @unchecked Sendable {
    /// Where the daemon is, for error text and the active-core badge.
    public let baseURL: String

    private let connection: WireConnection
    private let mirror: GRDBStore
    private let activityLog: SessionActivityLog

    private let lock = NSLock()
    private var handles: [String: RemoteLiveSession] = [:]
    private var createdListeners: [Int: (any LiveSession) -> Void] = [:]
    private var nextListenerToken = 1
    private var pending: LifecycleWaiter?
    /// The session the in-flight lifecycle request is about, so an error frame for
    /// some other session is not read as its answer. Nil for a `create`, which has no
    /// session id until it is acked.
    private var pendingSessionId: String?
    /// Per-session reporters for a seed the daemon accepted on `create` and could not
    /// deliver, keyed by session id. One entry lives from the create's ack until the
    /// daemon says the delivery failed, or until the session exits.
    private var seedFailureReporters: [String: @Sendable (String, String) -> Void] = [:]
    /// Sessions we have asked the core about but not yet heard back on, so one
    /// activity burst does not produce a dozen `attach` frames.
    private var probing: Set<String> = []
    private var nextSeq = 1
    private var loggedDroppedModel = false
    /// The handshake, once it has landed. A var rather than a let because the frame
    /// callbacks need `self` before the socket is open, so `self` has to be complete
    /// before the handshake can be waited on.
    private var handshake: WireConnection.Handshake?

    /// Serialises lifecycle requests: `create`, `reactivate` and
    /// `setSkipPermissions` all answer with an uncorrelated `created` + `attached`
    /// pair, so exactly one may be in flight per connection.
    private let lifecycleGate = NSLock()

    public let crashOrphanIds: Set<String>
    public let midTurnOrphanIds: Set<String>

    /// Connection state for the UI: false while the socket is down, with the reason.
    /// A dropped daemon has to be visible — a frozen pane that explains nothing is
    /// the failure mode this whole ticket exists to avoid.
    private var connectedFlag = true
    private var connectionListeners: [Int: @Sendable (Bool, String?) -> Void] = [:]

    /// The grid an attach we initiate uses when no pane has sized the session yet.
    /// Matches the daemon's own default so a discovery attach cannot narrow a
    /// session's transcript.
    private static let discoveryGrid = (cols: 120, rows: 40)

    // MARK: - Boot

    /// Connect to the daemon and wait for its handshake, so the caller knows the
    /// capability list before any UI is built. Throws when the daemon is not
    /// reachable, does not complete the handshake, or speaks a protocol version this
    /// app does not implement — all three are the "fail loudly" path, and the caller
    /// turns them into the offer to fall back to the Swift core.
    public static func connect(baseURL: String = Config.rustCoreBaseURL,
                               mirrorPath: String = Config.databasePath(for: .rust),
                               timeout: TimeInterval = 3.0) throws -> RustCoreClient {
        let url = try WireConnection.websocketURL(base: baseURL)
        let store = try GRDBStore(path: mirrorPath)
        return try RustCoreClient(url: url, baseURL: baseURL, mirror: store, timeout: timeout)
    }

    init(url: URL, baseURL: String, mirror: GRDBStore, timeout: TimeInterval) throws {
        self.baseURL = baseURL
        self.mirror = mirror
        self.activityLog = SessionActivityLog()

        // Rows the previous launch left marked running: their ptys may still be
        // alive in the daemon (it outlives this app), so they are marked dormant
        // here and re-adopted below if the daemon still has them.
        let orphans = Set(mirror.markOrphansDormant())
        self.crashOrphanIds = orphans
        self.midTurnOrphanIds = mirror.takeMidTurnIds().intersection(orphans)

        // Two-step init: the frame callbacks need `self`, so the connection is built
        // with trampolines that read a box this initialiser fills in.
        let box = SelfBox()
        self.connection = WireConnection(
            url: url,
            onFrame: { [box] frame in box.value?.handle(frame: frame) },
            onConnectionChange: { [box] up, reason in box.value?.connectionChanged(up: up, reason: reason) })
        box.value = self
        let landed = try connection.connectAndWaitForHandshake(
            timeout: timeout, expectedVersion: WireProtocol.version)
        lock.withLock { handshake = landed }

        // Re-adopt what the daemon may still be running. An `attach` for a session
        // it does not have answers one error frame and costs nothing.
        for id in orphans { probe(id) }
    }

    /// Serve the address every remote client knows (4280) for a launch on this
    /// core, so the oracle sidecar is not blind in rust mode.
    ///
    /// The daemon already speaks the wire protocol, but it serves only `/health`,
    /// `/api/health` and `/ws`: the sidecar's `GET /api/sessions`,
    /// `DELETE /api/sessions/:id` and `POST /api/pr-webhook` have nothing to answer
    /// them there, and protocol v1 has no frame that would let it list its own
    /// sessions (juancode-3l2p). So `/ws` is relayed to the daemon verbatim and the
    /// session reads come off this mirror, which is the only thing on the machine
    /// that has them.
    ///
    /// Best-effort, like the Swift core's embedded server: a taken port leaves the
    /// local shell fully working.
    public func startProxyServer(host: String, port: Int) {
        let source = CoreProxyServer.Source(
            sessions: { [weak self] in self?.sessions() ?? [] },
            session: { [weak self] id in self?.session(id) },
            searchSessions: { [weak self] q, limit in self?.searchSessions(q, limit: limit) ?? [] },
            kill: { [weak self] id in self?.kill(id) },
            deleteSession: { [weak self] id in self?.deleteSession(id) },
            backendName: backendName)
        let upstream = baseURL
        Task.detached {
            do {
                try await CoreProxyServer.run(source: source, upstreamBaseURL: upstream,
                                              host: host, port: port)
            } catch {
                NSLog("juancode: core proxy server did not start: \(error)")
            }
        }
    }

    // MARK: - Handshake

    public var info: CoreServerInfo {
        let landed = lock.withLock { handshake }
        return CoreServerInfo(protocolVersion: landed?.protocolVersion ?? WireProtocol.version,
                              capabilities: landed?.capabilities ?? [])
    }

    var backendName: String { "rust" }

    func supports(_ capability: CoreCapability) -> Bool { info.has(capability.rawValue) }

    /// Whether the socket is up right now.
    public var isConnected: Bool { lock.withLock { connectedFlag } }

    /// Watch the connection: `(up, reason)`. Called immediately with the current
    /// state so a subscriber never has to assume.
    @discardableResult
    public func onConnectionChange(_ listener: @escaping @Sendable (Bool, String?) -> Void) -> @Sendable () -> Void {
        let (token, state) = lock.withLock { () -> (Int, Bool) in
            let token = nextListenerToken
            nextListenerToken += 1
            connectionListeners[token] = listener
            return (token, connectedFlag)
        }
        listener(state, nil)
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connectionListeners[token] = nil }
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    public func create(provider: ProviderId, cwd: String, cols: Int, rows: Int,
                       opts: SpawnOptions, worktreePath: String?,
                       dispatchId: String?, initialInput: String?,
                       onSeedFailure: (@Sendable (String, String) -> Void)?) throws -> any LiveSession {
        let pinsModel = supports(.spawnModel)
        if opts.model != nil, !pinsModel {
            // The pin is dropped rather than faked: a core that does not advertise
            // `spawnModel` ignores the field, and the CLI picks its own model.
            // Said once per launch rather than per session.
            let already = lock.withLock { () -> Bool in
                defer { loggedDroppedModel = true }
                return loggedDroppedModel
            }
            if !already {
                NSLog("juancode: the \(backendName) core does not advertise `spawnModel`; the CLI's own default model is used")
            }
        }
        var frame: [String: Any] = [
            "type": "create",
            // A juancode-owned worktree is created by this app, and there is no
            // worktreePath on the wire, so the agent is started IN the worktree and
            // the row simply records that directory as its cwd.
            "provider": provider.rawValue,
            "cwd": worktreePath ?? cwd,
            "cols": cols,
            "rows": rows,
            "skipPermissions": opts.skipPermissions,
            "isolateWorktree": false,
        ]
        if let dispatchId { frame["dispatchId"] = dispatchId }
        if pinsModel, let model = opts.model, !model.isEmpty { frame["model"] = model }
        // The prompt travels on the create so the DAEMON delivers it: it owns the pty
        // and the parsed screen, so it is the only side that can confirm the paste
        // landed before pressing Enter. Delivering it from here instead is
        // `RemoteLiveSession.autoSubmit`, a blind paste plus a CR 120ms after the
        // CLI's first byte of output, which is seconds before its input box exists —
        // the prompt was typed into a booting TUI and never submitted.
        let seed = (initialInput?.isEmpty ?? true) ? nil : initialInput
        if let seed { frame["initialInput"] = seed }
        let handle = try lifecycle(frame, operation: "create", timeout: 60)
        // Registered after the ack because the daemon's verdict comes minutes later,
        // as its own frame, long after this create was answered.
        if seed != nil, let onSeedFailure {
            lock.withLock { seedFailureReporters[handle.id] = onSeedFailure }
        }
        return handle
    }

    @discardableResult
    public func createEditorSession(parent: SessionMeta, file: String?, line: Int?,
                                    cols: Int, rows: Int) throws -> any LiveSession {
        throw CoreCapabilityError(.editor, backend: backendName)
    }

    @discardableResult
    public func resume(_ meta: SessionMeta, cols: Int, rows: Int,
                       priorScrollback: [UInt8]) throws -> any LiveSession {
        try lifecycle(["type": "reactivate", "sessionId": meta.id, "cols": cols, "rows": rows],
                      operation: "reactivate", timeout: 60)
    }

    @discardableResult
    public func restartFresh(_ meta: SessionMeta, cols: Int, rows: Int) throws -> any LiveSession {
        guard supports(.restartFresh) else { throw CoreCapabilityError(.restartFresh, backend: backendName) }
        return try lifecycle(["type": "restartFresh", "sessionId": meta.id, "cols": cols, "rows": rows],
                             operation: "restartFresh", timeout: 60)
    }

    public func setSkipPermissions(_ sessionId: String, skipPermissions: Bool,
                                   cols: Int, rows: Int) async throws -> any LiveSession {
        let frame: [String: Any] = ["type": "setSkipPermissions", "sessionId": sessionId,
                                    "skipPermissions": skipPermissions, "cols": cols, "rows": rows]
        return try await Task.detached(priority: .userInitiated) { [self] in
            try lifecycle(frame, operation: "setSkipPermissions", timeout: 60)
        }.value
    }

    public func kill(_ sessionId: String) { sendKill(sessionId: sessionId) }

    // MARK: - Live sessions

    public func liveSession(_ id: String) -> (any LiveSession)? {
        let handle = lock.withLock { handles[id] }
        guard let handle, handle.isRunning else { return nil }
        return handle
    }

    public func liveSessions() -> [any LiveSession] {
        lock.withLock { Array(handles.values) }.filter(\.isRunning)
    }

    @discardableResult
    public func onSessionCreated(_ listener: @escaping (any LiveSession) -> Void) -> () -> Void {
        let token = lock.withLock { () -> Int in
            let token = nextListenerToken
            nextListenerToken += 1
            createdListeners[token] = listener
            return token
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.createdListeners[token] = nil }
        }
    }

    // MARK: - Persisted sessions (the desktop's mirror)

    public func sessions() -> [SessionMeta] { mirror.list() }

    public func session(_ id: String) -> SessionMeta? { mirror.get(id) }

    public func insertSession(_ meta: SessionMeta) { mirror.insert(meta) }

    public func updateSession(_ meta: SessionMeta, scrollback: [UInt8]) {
        mirror.update(meta, scrollback: scrollback)
    }

    public func deleteSession(_ id: String) { _ = mirror.delete(id) }

    public func storedScrollback(_ id: String) -> [UInt8]? { mirror.getScrollback(id) }

    public func setTitle(_ id: String, title: String) {
        if let handle = lock.withLock({ handles[id] }) { handle.setTitle(title) } else {
            mirror.setTitle(id, title: title)
        }
    }

    public func setArchived(_ id: String, archived: Bool) {
        if let handle = lock.withLock({ handles[id] }) { handle.setArchived(archived) } else {
            mirror.setArchived(id, archived: archived)
        }
    }

    public func setCliSessionId(_ id: String, cliSessionId: String) {
        mirror.setCliSessionId(id, cliSessionId: cliSessionId)
    }

    public func usedCliSessionIds() -> Set<String> { mirror.usedCliSessionIds() }

    public func searchSessions(_ query: String, limit: Int) -> [SearchHit] {
        mirror.search(query, limit: limit)
    }

    public func enforceSessionCap(projectKey: (String) -> String, keepIds: Set<String>) {
        _ = mirror.enforceSessionCap(projectKey: projectKey, keepIds: keepIds)
    }

    public func performMaintenance() throws -> GRDBStore.MaintenanceReport {
        try mirror.performMaintenance()
    }

    // MARK: - Message queue (capability: queue)

    @discardableResult
    public func queueMessage(_ sessionId: String, text: String) -> QueuedMessage {
        // Non-throwing by protocol shape, so this is the one place that can only log.
        // Every caller is gated on `supports(.queue)`; reaching here is a UI bug.
        NSLog("juancode: dropped a queued message — the \(backendName) core has no queue capability")
        return QueuedMessage(text: text)
    }

    public func queuedMessages(_ sessionId: String) -> [QueuedMessage] { [] }

    @discardableResult
    public func dequeueMessage(_ sessionId: String, messageId: String) -> Bool { false }

    @discardableResult
    public func subscribeQueue(_ sessionId: String,
                               _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void {
        // No snapshot and no callbacks: an empty queue that never changes is exactly
        // what a core without the capability has.
        {}
    }

    // MARK: - Ephemeral ptys (capabilities: editor, terminal)

    public func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty {
        throw CoreCapabilityError(.editor, backend: backendName)
    }

    public func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty {
        throw CoreCapabilityError(.terminal, backend: backendName)
    }

    // MARK: - Tracked PRs (capability: trackedPrs)

    public func trackedPrs() async -> [TrackedPr] { [] }

    public func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int) async -> TrackedPr? {
        NSLog("juancode: refused to track PR #\(pr.number) — the \(backendName) core has no trackedPrs capability")
        return nil
    }

    public func untrackPr(_ trackedId: String) async {}

    public func resolveTrackNotification(trackedId: String, notificationId: String) async {}

    public func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void {
        // The wire replies with the whole list on subscribe; an empty list is the
        // honest equivalent, and it keeps the panel's "nothing tracked" state right.
        onEvent(.trackedPrs([]))
        return {}
    }

    // MARK: - Presence, diagnostics, lifecycle

    /// No `/presence` on the daemon. The push gate it feeds is the sidecar's, which
    /// talks to whichever core is serving :4280 — not this one.
    public func markDesktopActive() {}

    public func logSessionEvent(_ event: String, sessionId: String, project: String,
                                fields: [String: String]) {
        activityLog.log(event, sessionId: sessionId, project: project, fields: fields)
    }

    public func flushSessionLog() -> String {
        activityLog.flush()
        return activityLog.logPath
    }

    /// The reaper runs inside a core; the daemon has one of its own and no frame to
    /// configure it. The Settings idle window therefore does not reach the rust core.
    public func setReaperIdleWindow(minutes: Int) async {}

    /// Same reason: the daemon owns its own reaper, so the open pane / active
    /// Oracle exemptions are pushed to nothing here.
    public func setReaperProtectedIds(_ ids: Set<String>) async {}

    /// Closing the app does NOT kill the daemon's ptys: it is another process, its
    /// sessions outlive this window, and re-adopting them is what the boot probe is
    /// for. All this does is persist what we know and hang up.
    public func shutdown() {
        persistLiveSnapshots()
        connection.stop()
    }

    public func shutdownGracefully(timeout: TimeInterval) {
        persistLiveSnapshots()
        connection.stop()
    }

    // MARK: - RemoteSessionTransport

    func sendInput(sessionId: String, text: String) {
        connection.send(["type": "input", "sessionId": sessionId, "data": text])
    }

    func sendResize(sessionId: String, cols: Int, rows: Int) -> Int {
        let seq = lock.withLock { () -> Int in
            let s = nextSeq
            nextSeq += 1
            return s
        }
        connection.send(["type": "resize", "sessionId": sessionId,
                         "cols": cols, "rows": rows, "seq": seq])
        return seq
    }

    func sendKill(sessionId: String) {
        connection.send(["type": "kill", "sessionId": sessionId])
    }

    func persist(_ meta: SessionMeta, scrollback: [UInt8]?) {
        if let scrollback {
            mirror.update(meta, scrollback: scrollback)
        } else {
            mirror.updateMeta(meta, reindexTitleFts: true)
        }
    }

    // MARK: - Frame handling

    private func handle(frame: WireConnection.Frame) {
        let body = frame.body
        let sessionId = body["sessionId"] as? String
        switch frame.type {
        case "created":
            guard let meta = Self.decodeMeta(body["session"]) else { return }
            upsert(meta, running: meta.status == .running)

        case "attached":
            guard let meta = Self.decodeMeta(body["session"]) else { return }
            let bytes = Array((body["scrollback"] as? String ?? "").utf8)
            let handle = upsert(meta, running: meta.status == .running)
            handle.apply(attachedScrollback: bytes, meta: meta)
            // An attach WE initiated to discover a session is not the answer to a
            // create or a reactivate that happens to be in flight.
            let wasProbe = lock.withLock { probing.remove(meta.id) != nil }
            if !wasProbe { pendingResult { $0.attached = handle } }

        case "output":
            guard let id = sessionId, let data = body["data"] as? String else { return }
            handleFor(id)?.apply(output: Array(data.utf8))

        case "activity":
            guard let id = sessionId,
                  let raw = body["state"] as? String,
                  let state = SessionActivity(rawValue: raw) else { return }
            let notify = body["notify"] as? Bool ?? false
            if let handle = handleFor(id) {
                handle.apply(activity: state, notify: notify)
            } else {
                // A session this app has never seen: the daemon outlives us, so this
                // is how a session from a previous launch (or another client)
                // announces itself. Ask for it.
                probe(id)
            }

        case "exit":
            guard let id = sessionId else { return }
            // Nothing more will be said about a seed for a session that is gone: the
            // daemon reports an exit during a delivery as the delivery's own failure,
            // which has already been routed by the time this arrives.
            lock.withLock { seedFailureReporters[id] = nil }
            let code = body["exitCode"] as? Int
            if let handle = handleFor(id) {
                handle.apply(exitCode: code)
            } else if var row = mirror.get(id) {
                row.status = .exited
                row.exitCode = code
                row.updatedAt = nowMs()
                mirror.updateMeta(row, reindexTitleFts: false)
            }

        case "resizeAck":
            guard let id = sessionId, let handle = handleFor(id) else { return }
            handle.apply(resizeAck: body["cols"] as? Int ?? 0, rows: body["rows"] as? Int ?? 0,
                         applied: body["applied"] as? Bool ?? false,
                         denied: body["denied"] as? Bool ?? false,
                         owner: body["owner"] as? String)

        case "gridChange":
            guard let id = sessionId, let handle = handleFor(id) else { return }
            handle.apply(gridOwner: body["owner"] as? String,
                         cols: body["cols"] as? Int ?? 0, rows: body["rows"] as? Int ?? 0)

        case "sessionMeta":
            guard let meta = Self.decodeMeta(body["session"]) else { return }
            let handle = upsert(meta, running: meta.status == .running)
            handle.apply(meta: meta)

        case "unresumable":
            let reason = body["reason"] as? String ?? "unresumable"
            if let id = sessionId { lock.withLock { _ = probing.remove(id) } }
            pendingResult { $0.failure = CoreRemoteError(message: reason, sessionId: sessionId) }

        case "error":
            let message = body["message"] as? String ?? "unknown core error"
            // A seed the daemon could not deliver is reported as an error frame for
            // that session, arriving long after the create it belongs to was acked. It
            // is nobody's answer, so it must reach the session's own reporter rather
            // than fail whichever lifecycle request happens to be in flight — and an
            // error naming the session a request IS about stays that request's answer.
            if let id = sessionId,
               let report = lock.withLock({ () -> (@Sendable (String, String) -> Void)? in
                   guard pendingSessionId != id else { return nil }
                   return seedFailureReporters.removeValue(forKey: id)
               }) {
                NSLog("juancode: rust core did not deliver the prompt for \(id): \(message)")
                report(id, message)
                return
            }
            if let id = sessionId, lock.withLock({ probing.remove(id) }) != nil {
                // A probe for a session the daemon does not have: expected, and not
                // the answer to whatever lifecycle request may be in flight.
                NSLog("juancode: rust core has no session \(id) (\(message))")
                return
            }
            pendingResult { $0.failure = CoreRemoteError(message: message, sessionId: sessionId) }

        case "inputAck", "screen", "queue", "editorReady", "terminalReady",
             "trackedPrs", "trackNotification":
            // Either not subscribed to (screen), or a capability this client does not
            // use against a core that does not advertise it. Ignored, not fatal.
            break

        default:
            break
        }
    }

    private func connectionChanged(up: Bool, reason: String?) {
        let listeners: [@Sendable (Bool, String?) -> Void] = lock.withLock {
            connectedFlag = up
            return Array(connectionListeners.values)
        }
        if up {
            // Re-attach everything we hold: a reconnect is a new connection to the
            // core, which knows nothing about what this one had attached.
            for handle in lock.withLock({ Array(handles.values) }) where handle.isRunning {
                let grid = handle.attachGrid ?? Self.discoveryGrid
                connection.send(["type": "attach", "sessionId": handle.id,
                                 "cols": grid.cols, "rows": grid.rows])
            }
        } else if let reason {
            NSLog("juancode: rust core connection lost (\(reason))")
        }
        for l in listeners { l(up, reason) }
    }

    // MARK: - Internals

    private func handleFor(_ id: String) -> RemoteLiveSession? { lock.withLock { handles[id] } }

    /// Create or refresh the handle for `meta`, mirror the row, and announce a new
    /// handle to `onSessionCreated` subscribers.
    @discardableResult
    private func upsert(_ meta: SessionMeta, running: Bool) -> RemoteLiveSession {
        let (handle, isNew, listeners) = lock.withLock { () -> (RemoteLiveSession, Bool, [(any LiveSession) -> Void]) in
            if let existing = handles[meta.id] {
                return (existing, false, [])
            }
            let fresh = RemoteLiveSession(meta: meta, running: running, transport: self,
                                          clientId: handshake?.clientId)
            handles[meta.id] = fresh
            return (fresh, true, Array(createdListeners.values))
        }
        // Mirror first, then notify: a listener that reacts by reading the row back
        // (the sidebar does) must not see the row the frame just superseded.
        if mirror.get(meta.id) == nil {
            mirror.insert(meta)
        } else {
            mirror.updateMeta(meta, reindexTitleFts: true)
        }
        if !isNew { handle.apply(meta: meta) }
        if isNew { for l in listeners { l(handle) } }
        return handle
    }

    /// Ask the core about a session we have an id for but no handle. `attach` is the
    /// only frame that answers with a session's meta, so it doubles as the lookup.
    private func probe(_ id: String) {
        let shouldSend = lock.withLock { probing.insert(id).inserted }
        guard shouldSend else { return }
        connection.send(["type": "attach", "sessionId": id,
                         "cols": Self.discoveryGrid.cols, "rows": Self.discoveryGrid.rows])
    }

    private func persistLiveSnapshots() {
        for handle in lock.withLock({ Array(handles.values) }) {
            let snapshot = handle.snapshotForMirror
            mirror.update(snapshot.meta, scrollback: snapshot.scrollback)
        }
    }

    /// Send a lifecycle frame and block until the core answers with the
    /// `created` + `attached` pair, an `unresumable`, or an `error`.
    private func lifecycle(_ frame: [String: Any], operation: String,
                           timeout: TimeInterval) throws -> any LiveSession {
        lifecycleGate.lock()
        defer { lifecycleGate.unlock() }
        let waiter = LifecycleWaiter()
        let target = frame["sessionId"] as? String
        lock.withLock {
            pending = waiter
            pendingSessionId = target
        }
        defer { lock.withLock { pending = nil; pendingSessionId = nil } }
        connection.send(frame)
        guard waiter.wait(timeout: timeout) else {
            throw CoreRemoteError(
                message: "the \(backendName) core did not answer \(operation) within \(Int(timeout))s",
                sessionId: frame["sessionId"] as? String)
        }
        if let failure = waiter.failure { throw failure }
        guard let handle = waiter.attached else {
            throw CoreRemoteError(message: "the \(backendName) core answered \(operation) without an attached session",
                                  sessionId: frame["sessionId"] as? String)
        }
        return handle
    }

    /// Feed the in-flight lifecycle waiter, if there is one.
    private func pendingResult(_ mutate: (LifecycleWaiter) -> Void) {
        guard let waiter = lock.withLock({ pending }) else { return }
        mutate(waiter)
        waiter.settleIfDone()
    }

    static func decodeMeta(_ raw: Any?) -> SessionMeta? {
        guard let raw, JSONSerialization.isValidJSONObject(["session": raw]),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        do {
            return try JSONDecoder().decode(SessionMeta.self, from: data)
        } catch {
            NSLog("juancode: could not decode a session from the core: \(error)")
            return nil
        }
    }
}

/// An error the core reported, or a request it never answered.
public struct CoreRemoteError: LocalizedError {
    public let message: String
    public let sessionId: String?

    public init(message: String, sessionId: String?) {
        self.message = message
        self.sessionId = sessionId
    }

    public var errorDescription: String? { message }
}

/// One in-flight lifecycle request. `created` then `attached` is the reply pair;
/// either an `unresumable` or an `error` ends it early.
private final class LifecycleWaiter: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var settled = false

    var attached: RemoteLiveSession? {
        get { lock.withLock { _attached } }
        set { lock.withLock { _attached = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    private var _attached: RemoteLiveSession?
    private var _failure: Error?

    func settleIfDone() {
        let signal: Bool = lock.withLock {
            guard !settled, _attached != nil || _failure != nil else { return false }
            settled = true
            return true
        }
        if signal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

/// Lets an initialiser hand `self` to callbacks it has to build before `self`
/// exists. Written once rather than repeated per closure.
private final class SelfBox: @unchecked Sendable {
    weak var value: RustCoreClient?
}
