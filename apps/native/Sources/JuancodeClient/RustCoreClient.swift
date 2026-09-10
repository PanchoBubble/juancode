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
/// `serverInfo.capabilities` — the authoritative list is `CAPABILITIES` in
/// `juancoded-server/src/wire.rs`, and this client reads the one the connected core
/// actually sent rather than a copy of it. `editor` and `terminal` are the notable
/// absences today. Every member backed by a capability the connected core lacks either
/// throws `CoreCapabilityError` (so a caller that got past the UI gate is a visible
/// bug) or answers empty, and the UI reads the same list to grey the affordance out
/// with the reason. Nothing here silently succeeds.
///
/// **The mirror is a cache of the core's store.** The daemon owns its own SQLite at
/// `$JUANCODED_DATA_DIR/juancoded-rust.db` (default `~/.juancode/rust-core`) and is
/// its only writer, so the sidebar, the search index and the retention cap read a
/// desktop-side mirror at `<dataDir>/juancode-rust.db` instead. It is deliberately a
/// different file from the Swift core's `juancode.db`: one writer per file, and no
/// schema drift between two cores.
///
/// What makes it a cache rather than a tally is `listSessions`. The mirror used to be
/// fed only from `created`/`attached`/`sessionMeta`/`exit`, which are all deltas that
/// reach a client only while it is connected — so a fresh launch started empty and
/// filled in as sessions were touched, and the sidebar looked like it had lost every
/// project (28 sessions against the daemon's 379, measured 2026-08-24, juancode-75c5).
/// Now the handshake asks for the whole list and `backfill` reconciles the mirror
/// against it, deletions included; the deltas keep it current afterwards.
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
    /// Signalled once a `sessions` snapshot has been applied to the mirror, so boot
    /// can wait for the sidebar's rows the way it already waits for the handshake.
    /// Nil once the wait is over: a later snapshot (a reconnect) has nobody to wake.
    private var backfillWaiter: DispatchSemaphore?

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
    /// The last reaper policy this client pushed, so a reconnect can re-state it. The
    /// daemon is a separate process: its never-sleep set is per connection and its
    /// window resets to its own boot default when it restarts.
    private var reaperWindowMinutes: Int?
    private var reaperProtectedIds: Set<String>?
    private var connectionListeners: [Int: @Sendable (Bool, String?) -> Void] = [:]
    /// The tracked-PR watch list as the daemon last sent it, or nil while this
    /// connection has never been sent one. Nil and empty are different answers: the
    /// daemon sends the whole list on subscribe, so empty means "nothing is watched"
    /// and nil means "we have not been told yet".
    private var trackedList: [TrackedPr]?
    private var trackedListeners: [Int: @Sendable (TrackedPrEvent) -> Void] = [:]
    /// Whether `subscribeTrackedPrs` has been sent on THIS socket. The subscription is
    /// per connection on the daemon's side, so a reconnect has to send it again.
    private var trackedSubscribed = false
    /// One-shot waiters for the next `trackedPrs` frame: what `trackedPrs()` and
    /// `trackPr` wait on, since the daemon answers both with the list on the bus
    /// rather than with a reply of their own.
    private var trackedWaiters: [FrameWaiter] = []

    /// Each session's steering queue as the daemon last sent it, keyed by session id.
    /// A missing key and an empty array are different answers: the daemon answers
    /// `subscribeQueue` with the whole queue, so empty means "nothing is pending" and
    /// missing means "this connection has not been told yet".
    private var queueSnapshots: [String: [QueuedMessage]] = [:]
    /// The revision the cached snapshot came at, so a snapshot that somehow arrives out
    /// of order is dropped rather than allowed to un-do a newer one. Per session and
    /// strictly increasing on the daemon's side; not a cursor, there is nothing to
    /// fetch between two of them.
    private var queueRevisions: [String: Int] = [:]
    private var queueListeners: [String: [Int: MessageQueue.Listener]] = [:]
    /// Sessions `subscribeQueue` has been sent for on THIS socket. Per connection on
    /// the daemon's side, so a reconnect has to send them all again.
    private var queueSubscribed: Set<String> = []
    /// One-shot waiters for the next `queue` frame per session: what a first read waits
    /// on, since the daemon answers a subscribe with the snapshot on the bus rather
    /// than with a reply of its own.
    private var queueFrameWaiters: [String: [FrameWaiter]] = [:]
    /// Queue writes still waiting for the core's answer, per session. This is the list
    /// that makes a failed write fail: a write stays here until a snapshot carries its
    /// row, an `error` frame refuses it, or its budget runs out.
    private var queueWrites: [String: [QueueWrite]] = [:]

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

        // Ask for the whole list before anything reads the mirror. Bounded, and a
        // timeout is not fatal: the snapshot lands whenever it lands and the sidebar
        // catches up, which is strictly better than the old behaviour of never
        // asking. Waiting at all is what makes a launch show the daemon's history
        // rather than an empty sidebar that fills in as sessions are touched.
        if landed.capabilities.contains(Self.sessionListCapability) {
            let waiter = DispatchSemaphore(value: 0)
            lock.withLock { backfillWaiter = waiter }
            connection.send(["type": "listSessions"])
            if waiter.wait(timeout: .now() + Self.backfillTimeout) == .timedOut {
                NSLog("juancode: rust core did not answer listSessions within "
                      + "\(Int(Self.backfillTimeout * 1000))ms; the sidebar will fill in late")
            }
            lock.withLock { backfillWaiter = nil }
        }

        // Answer a remote pause without a desktop, the same way `AppState` does for
        // the Swift core. Replaced by the model's own pause when the app comes up.
        globalPause.driver = RemoteGlobalPause(core: self, book: globalPause)

        // Re-adopt what the daemon may still be running. An `attach` for a session
        // it does not have answers one error frame and costs nothing.
        for id in orphans { probe(id) }
    }

    /// The capability behind `listSessions`/`sessions`, spelled once.
    ///
    /// A string rather than a `CoreCapability` case because the enum is the list the
    /// Settings screen renders and a gated button reads its excuse from, and there is
    /// no button here: a client either restores its sidebar from the core or does not.
    static let sessionListCapability = "sessionList"
    /// The capability behind `deleteSession`/`sessionDeleted`, same reasoning.
    static let sessionDeleteCapability = "sessionDelete"
    /// The capability behind `sleepSession`.
    ///
    /// A string rather than a `CoreCapability` case for the same reason `reaper` is:
    /// the enum is the list whose every name the Swift core advertises, and the Swift
    /// core sleeps a session in-process with no frame at all. A case here would make
    /// the capability panel report "cannot sleep a session" for the one core that
    /// always could. There is no gated button either — a pause on a core without the
    /// frame still pauses, it just leaves a row that reads as a kill.
    static let sessionSleepCapability = "sessionSleep"
    /// The capability behind `setMeta`.
    ///
    /// A string rather than a `CoreCapability` case for the same reason
    /// `sessionSleep` is: the enum is the list whose every name the Swift core
    /// advertises, and the Swift core renames a session in-process with no frame at
    /// all. There is no gated button either — a rename on a core without the frame
    /// still renames, it just does not survive the core's next broadcast, which is a
    /// thing to log rather than a thing to grey out.
    static let sessionEditCapability = "sessionEdit"
    /// How long boot waits for the first `sessions` snapshot. Long enough for the
    /// daemon to serialise a few hundred rows, short enough that an unresponsive core
    /// costs a late sidebar rather than a launch.
    private static let backfillTimeout: TimeInterval = 5.0
    /// How long a read of the watch list waits for the daemon's answer.
    private static let trackedListTimeout: TimeInterval = 5.0
    /// How long `trackPr` waits for the PR to appear in the list. Generous, because
    /// tracking fetches a branch and boots a CLI before the row exists.
    private static let trackTimeout: TimeInterval = 45.0
    /// How long a queue write waits for the core's answer. Short, because the daemon
    /// publishes the snapshot inside the same enqueue that mints the row, so this is
    /// one round trip and not any real work — a budget that ran out means the write did
    /// not happen, and the user is told so.
    private static let queueWriteTimeout: TimeInterval = 5.0

    /// The capability behind `editQueuedConfirmed`.
    ///
    /// A string rather than a `CoreCapability` case for the same reason `reaper` and
    /// `sessionSleep` are: the enum is the list whose every name the Swift core
    /// advertises, and the Swift core's in-process queue has no edit at all. A case
    /// here would make the capability panel report a missing feature on both cores
    /// while no surface offers one.
    static let queueEditCapability = "queueEdit"

    /// Serve the address every remote client knows (4280) for a launch on this
    /// core, so the oracle sidecar is not blind in rust mode.
    ///
    /// The daemon already speaks the wire protocol, but it serves only `/health`,
    /// `/api/health` and `/ws`: the sidecar's `GET /api/sessions`,
    /// `DELETE /api/sessions/:id` and `POST /api/pr-webhook` have nothing to answer
    /// them there. So `/ws` is relayed to the daemon verbatim and the session reads
    /// come off this mirror — which is now the daemon's own list, backfilled on the
    /// handshake, rather than only what this desktop happened to watch arrive.
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
            backendName: backendName,
            globalPause: globalPause)
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

    /// This launch's paused set. The daemon has no frame for a global pause and no
    /// row that distinguishes "the pause slept this" from the four other things that
    /// set `dormant`, so the book lives on the desktop side of the wire — one
    /// instance, shared by the local UI and by the `/ws` surface the proxy serves.
    public let globalPause = GlobalPauseBook()

    public var info: CoreServerInfo {
        let landed = lock.withLock { handshake }
        return CoreServerInfo(protocolVersion: landed?.protocolVersion ?? WireProtocol.version,
                              capabilities: landed?.capabilities ?? [],
                              daemon: landed?.daemon)
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

    /// Forget a session: the daemon's row and worktree as well as this mirror's row.
    ///
    /// Dropping the mirror row on its own is what this used to do, and it is the bug
    /// juancode-lxe3 is about: the daemon kept its own row, so the session came back
    /// the next time anything listed or adopted, and the worktree it owned was left
    /// for a sweep to find. Local-only is still the honest answer on a core with no
    /// `sessionDelete` — the alternative is a delete button that does nothing.
    public func deleteSession(_ id: String) {
        // Local first, then the frame. The caller reads its session list back
        // immediately — the sidebar refresh is the next statement after this — so
        // waiting for the daemon's answer to drop the row would leave the deleted
        // session on screen until something else happened to refresh. `forget` is
        // idempotent, so the broadcast that follows costs nothing here and is what
        // does the work on every OTHER client.
        forget(id)
        guard supportsSessionDelete else {
            NSLog("juancode: the \(backendName) core has no sessionDelete capability — "
                  + "\(id) is forgotten locally only; the core keeps its own row")
            return
        }
        connection.send(["type": "deleteSession", "sessionId": id])
    }

    /// Whether the connected core can really forget a session.
    var supportsSessionDelete: Bool { info.has(Self.sessionDeleteCapability) }

    public func storedScrollback(_ id: String) -> [UInt8]? { mirror.getScrollback(id) }

    /// Rename a session, with or without a live handle for it.
    ///
    /// Both paths write the mirror row AND send the frame, and the frame is the half
    /// that makes the rename last: the mirror is a cache the core's own `sessionMeta`
    /// broadcasts and its boot backfill both replace, so a name written only here
    /// survived until the CLI painted its next OSC window title (juancode-0yao). The
    /// handle-less path is the common one for a rename — most renamed sessions are
    /// ones nobody has a pane open on — so it cannot be the one that only writes the
    /// cache.
    public func setTitle(_ id: String, title: String) {
        if let handle = lock.withLock({ handles[id] }) { handle.setTitle(title) } else {
            mirror.setTitle(id, title: title)
            sendSetMeta(sessionId: id, title: title, archived: nil)
        }
    }

    public func setArchived(_ id: String, archived: Bool) {
        if let handle = lock.withLock({ handles[id] }) { handle.setArchived(archived) } else {
            mirror.setArchived(id, archived: archived)
            sendSetMeta(sessionId: id, title: nil, archived: archived)
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

    // The daemon's queue has always been real; this client was the part that was not.
    // `queueMessage` used to log a line and hand back a `QueuedMessage` nobody held, so
    // "Send to agent" and "Submit review" returned focus, cleared their baskets and
    // archived their comments while the agent received nothing (juancode-rzl7). The
    // phone could queue over the same daemon the whole time.
    //
    // The shape is the tracked-PR list's: one `subscribeQueue` per connection per
    // session, and a cached snapshot the daemon replaces wholesale — there is no delta
    // frame, so a client's whole job is to drop what it was holding. One thing is added
    // on top of that, and it matters more than the caching: a write is not reported as
    // done until the core has said it is done. `connection.send` is fire-and-forget
    // over a socket that may be down, the daemon refuses a message addressed to a
    // session it does not have (`queue-item-not-found`) and drops a whitespace-only one
    // without a word. All three used to read as success.

    /// One `subscribeQueue` per session per connection, so the snapshots this client
    /// confirms writes against actually arrive. Idempotent on the daemon's side too.
    private func ensureQueueSubscription(_ sessionId: String) {
        guard supports(.queue) else { return }
        let send: Bool = lock.withLock {
            queueSubscribed.insert(sessionId).inserted
        }
        if send { connection.send(["type": "subscribeQueue", "sessionId": sessionId]) }
    }

    /// The session's queue as the daemon last sent it, subscribing and waiting for the
    /// baseline when this connection has never been told. Nil when nothing answered.
    ///
    /// A write needs this before it goes out, not after: the ids in the baseline are
    /// what tell the row the daemon is about to mint apart from a row that was already
    /// pending with the same text. Subscribing and writing in one breath would leave the
    /// baseline racing the confirmation.
    private func queueBaseline(_ sessionId: String) async -> [QueuedMessage]? {
        if let known = lock.withLock({ queueSnapshots[sessionId] }) { return known }
        let waiter = FrameWaiter()
        lock.withLock { queueFrameWaiters[sessionId, default: []].append(waiter) }
        ensureQueueSubscription(sessionId)
        let expiry = Task { [weak waiter] in
            await Nap.ms(Int(Self.queueWriteTimeout * 1000))
            waiter?.expire()
        }
        let landed = await waiter.landed()
        expiry.cancel()
        lock.withLock {
            queueFrameWaiters[sessionId]?.removeAll { $0 === waiter }
            if queueFrameWaiters[sessionId]?.isEmpty == true { queueFrameWaiters[sessionId] = nil }
        }
        guard landed else { return nil }
        return lock.withLock { queueSnapshots[sessionId] }
    }

    /// Queue a message and wait for the core to confirm the row exists.
    ///
    /// Throws rather than returns an optional so a caller cannot drop the answer by
    /// accident, and throws on silence as well as on a refusal: a write nobody
    /// confirmed has not happened, and reporting it as though it had is the whole bug.
    public func queueMessageConfirmed(_ sessionId: String, text: String) async throws -> QueuedMessage {
        guard supports(.queue) else { throw CoreCapabilityError(.queue, backend: backendName) }
        // The daemon drops a whitespace-only message without a snapshot, deliberately —
        // it is not a message. Refused here with a reason rather than sent to wait out
        // the timeout on a frame that is never coming.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "there was nothing to send: the message is empty")
        }
        guard isConnected else {
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "the \(backendName) core at \(baseURL) is not connected")
        }
        guard let baseline = await queueBaseline(sessionId) else {
            throw QueueWriteError(
                sessionId: sessionId,
                reason: "the \(backendName) core did not answer subscribeQueue within "
                    + "\(Int(Self.queueWriteTimeout))s, so nothing was queued")
        }
        let write = QueueWrite(text: text, knownIds: Set(baseline.map(\.id)))
        lock.withLock { queueWrites[sessionId, default: []].append(write) }
        connection.send(["type": "queueMessage", "sessionId": sessionId, "text": text])
        let expiry = Task { [weak write] in
            await Nap.ms(Int(Self.queueWriteTimeout * 1000))
            write?.timeOut()
        }
        let answer = await write.answer()
        expiry.cancel()
        lock.withLock {
            queueWrites[sessionId]?.removeAll { $0 === write }
            if queueWrites[sessionId]?.isEmpty == true { queueWrites[sessionId] = nil }
        }
        switch answer {
        case .queued(let item):
            return item
        case .refused(let code):
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "the \(backendName) core refused it (\(code))")
        case .timedOut:
            throw QueueWriteError(
                sessionId: sessionId,
                reason: "the \(backendName) core did not confirm it within "
                    + "\(Int(Self.queueWriteTimeout))s")
        }
    }

    /// Sync by protocol shape, which is the one thing this frame cannot be on a remote
    /// core: the confirmation is a snapshot that arrives later. So this sends the frame
    /// and hands back the row the DAEMON has not seen yet, and every caller in the app
    /// uses `queueMessageConfirmed` instead — the gates in `AppModel` do.
    ///
    /// Kept because it is a protocol requirement, and loud rather than silent: the
    /// returned id is this client's, not the daemon's, and nothing may treat it as a
    /// receipt.
    @discardableResult
    public func queueMessage(_ sessionId: String, text: String) -> QueuedMessage {
        let optimistic = QueuedMessage(text: text)
        guard supports(.queue) else {
            NSLog("juancode: dropped a queued message — the \(backendName) core has no queue capability")
            return optimistic
        }
        NSLog("juancode: queued a message for \(sessionId) without waiting for the "
              + "\(backendName) core to confirm it — use queueMessageConfirmed")
        ensureQueueSubscription(sessionId)
        connection.send(["type": "queueMessage", "sessionId": sessionId, "text": text])
        return optimistic
    }

    /// The cached snapshot. Empty and "never told" are different answers and this
    /// signature can only give one of them, so the first read of a session subscribes
    /// and says so in the log; the next one has the daemon's list. A caller that needs
    /// the list rather than whatever is cached uses `subscribeQueue`, whose first
    /// callback IS the daemon's snapshot.
    public func queuedMessages(_ sessionId: String) -> [QueuedMessage] {
        guard supports(.queue) else { return [] }
        if let known = lock.withLock({ queueSnapshots[sessionId] }) { return known }
        NSLog("juancode: no queue snapshot for \(sessionId) yet — subscribing; "
              + "this read answers empty rather than unknown")
        ensureQueueSubscription(sessionId)
        return []
    }

    /// Cancel a pending row. The daemon's verdict is the next snapshot (a refusal is an
    /// `error` frame with `queue-item-not-found`), so the `Bool` this signature owes a
    /// caller can only say whether the row was still pending in the cache when the
    /// frame went out — never that the core accepted it.
    @discardableResult
    public func dequeueMessage(_ sessionId: String, messageId: String) -> Bool {
        guard supports(.queue) else { return false }
        guard isConnected else {
            NSLog("juancode: cannot dequeue \(messageId) — the \(backendName) core is not connected")
            return false
        }
        let known = lock.withLock { queueSnapshots[sessionId] }
        ensureQueueSubscription(sessionId)
        connection.send(["type": "dequeueMessage", "sessionId": sessionId, "messageId": messageId])
        return known?.contains { $0.id == messageId } ?? false
    }

    /// Rewrite a pending row's text in place, keeping its id and its slot in delivery
    /// order (wire `editQueued`, capability `queueEdit`). Confirmed the same way a
    /// queue is: the snapshot that carries the new text, or the refusal.
    public func editQueuedConfirmed(_ sessionId: String, messageId: String,
                                    text: String) async throws -> QueuedMessage {
        guard supports(.queue), info.has(Self.queueEditCapability) else {
            throw CoreOperationUnsupported(
                operation: "Editing a queued message", backend: backendName,
                detail: "this core does not advertise the queueEdit capability")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "an edit cannot blank a queued message")
        }
        guard isConnected else {
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "the \(backendName) core at \(baseURL) is not connected")
        }
        // An edit names a row, so it needs no baseline to tell rows apart: the
        // confirmation is that id carrying the new text.
        let write = QueueWrite(text: text, knownIds: [], editing: messageId)
        lock.withLock { queueWrites[sessionId, default: []].append(write) }
        connection.send(["type": "editQueued", "sessionId": sessionId,
                         "messageId": messageId, "text": text])
        let expiry = Task { [weak write] in
            await Nap.ms(Int(Self.queueWriteTimeout * 1000))
            write?.timeOut()
        }
        let answer = await write.answer()
        expiry.cancel()
        lock.withLock {
            queueWrites[sessionId]?.removeAll { $0 === write }
            if queueWrites[sessionId]?.isEmpty == true { queueWrites[sessionId] = nil }
        }
        switch answer {
        case .queued(let item):
            return item
        case .refused(let code):
            throw QueueWriteError(sessionId: sessionId,
                                  reason: "the \(backendName) core refused the edit (\(code))")
        case .timedOut:
            throw QueueWriteError(
                sessionId: sessionId,
                reason: "the \(backendName) core did not confirm the edit within "
                    + "\(Int(Self.queueWriteTimeout))s")
        }
    }

    /// Watch a session's queue. The listener is handed the cached snapshot when this
    /// connection already has one, and otherwise the daemon's answer to the
    /// `subscribeQueue` this sends reaches it as the first callback — the same
    /// hand-over rule `subscribeTrackedPrs` follows, and for the same reason: delivering
    /// it here as well would deliver it twice.
    ///
    /// Cancelling drops the listener and leaves the per-connection subscription in
    /// place. The cache it feeds is what a write is confirmed against, and a session
    /// this app has queued to is one it will queue to again.
    @discardableResult
    public func subscribeQueue(_ sessionId: String,
                               _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void {
        guard supports(.queue) else { return {} }
        let (token, known) = lock.withLock { () -> (Int, [QueuedMessage]?) in
            let t = nextListenerToken
            nextListenerToken += 1
            queueListeners[sessionId, default: [:]][t] = listener
            return (t, queueSnapshots[sessionId])
        }
        ensureQueueSubscription(sessionId)
        if let known { listener(known) }
        return { [weak self] in
            guard let self else { return }
            lock.withLock {
                self.queueListeners[sessionId]?[token] = nil
                if self.queueListeners[sessionId]?.isEmpty == true {
                    self.queueListeners[sessionId] = nil
                }
            }
        }
    }

    // MARK: - Ephemeral ptys (capabilities: editor, terminal)

    public func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty {
        throw CoreCapabilityError(.editor, backend: backendName)
    }

    public func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty {
        throw CoreCapabilityError(.terminal, backend: backendName)
    }

    // MARK: - Tracked PRs (capability: trackedPrs)

    /// One subscription per connection, sent once and again after a reconnect. The
    /// daemon answers it with the whole list, which is what fills `trackedList`.
    private func ensureTrackedSubscription() {
        guard supports(.trackedPrs) else { return }
        let send: Bool = lock.withLock {
            guard !trackedSubscribed else { return false }
            trackedSubscribed = true
            return true
        }
        if send { connection.send(["type": "subscribeTrackedPrs"]) }
    }

    /// Wait for the next `trackedPrs` frame. `false` when the budget ran out first.
    ///
    /// A wait rather than a round trip because the tracked-PR frames are deliberately
    /// answered by a list on the bus: every subscriber has to hear the same list, so
    /// two clients on one daemon cannot disagree about what is being watched. The frame
    /// handler writes `trackedList` before it wakes anybody, so a caller reads the
    /// cache once this returns.
    private func awaitTrackedFrame(timeout: TimeInterval) async -> Bool {
        let waiter = FrameWaiter()
        lock.withLock { trackedWaiters.append(waiter) }
        // Cancelled as soon as the frame lands. `FrameWaiter` is one-shot, so the
        // expiry a cancelled `Nap` still runs into cannot wake anybody twice.
        let expiry = Task { [weak waiter] in
            await Nap.ms(Int(timeout * 1000))
            waiter?.expire()
        }
        let landed = await waiter.landed()
        expiry.cancel()
        lock.withLock { trackedWaiters.removeAll { $0 === waiter } }
        return landed
    }

    public func trackedPrs() async -> [TrackedPr] {
        guard supports(.trackedPrs) else { return [] }
        ensureTrackedSubscription()
        if let known = lock.withLock({ trackedList }) { return known }
        _ = await awaitTrackedFrame(timeout: Self.trackedListTimeout)
        return lock.withLock { trackedList } ?? []
    }

    public func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int,
                        adoptSessionId: String?) async -> TrackedPr? {
        guard supports(.trackedPrs) else {
            NSLog("juancode: refused to track PR #\(pr.number) — the \(backendName) core has no trackedPrs capability")
            return nil
        }
        if let adoptSessionId {
            // Protocol v1's `trackPr` carries no session to adopt into, so there is no
            // frame for this and inventing one client-side would mean spawning a second
            // agent for a PR the user asked to be watched by the session they are
            // already sitting in. Refused rather than silently turned into a spawn.
            NSLog("juancode: cannot track PR #\(pr.number) in session \(adoptSessionId) — "
                  + "the \(backendName) core has no wire frame for tracking in an existing session")
            return nil
        }
        // The list this track produces is the answer, so the subscription has to be in
        // place before the frame goes out. `cols`/`rows` have nowhere to go: protocol
        // v1's `trackPr` carries no grid, so the daemon spawns the agent at its own
        // default — which is the same 120x40 a create with no viewport gets, so the
        // agent's first turn is not wrapped narrow either way.
        ensureTrackedSubscription()
        connection.send([
            "type": "trackPr",
            "cwd": cwd,
            "pr": [
                "number": pr.number,
                "title": pr.title,
                "url": pr.url,
                "branch": pr.branch,
            ],
        ])
        // Tracking makes a worktree (a fetch among the git it runs) and spawns a CLI,
        // so the list takes seconds rather than milliseconds. Every list until the
        // deadline is looked at, because another client's untrack can put one on the
        // bus first. A timeout is not a failure to track — the list lands whenever it
        // lands and every subscriber gets it — it only means this call cannot name the
        // row, which is the same nil an already-tracked PR answers with.
        let deadline = Date().addingTimeInterval(Self.trackTimeout)
        let id = TrackedPr.key(cwd: cwd, number: pr.number)
        while true {
            if let entry = lock.withLock({ trackedList })?.first(where: { $0.id == id }) {
                return entry
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, await awaitTrackedFrame(timeout: remaining) else { break }
        }
        NSLog("juancode: the \(backendName) core did not report PR #\(pr.number) as tracked within "
              + "\(Int(Self.trackTimeout))s")
        return nil
    }

    public func untrackPr(_ trackedId: String) async {
        guard supports(.trackedPrs) else { return }
        connection.send(["type": "untrackPr", "trackedId": trackedId])
    }

    public func resolveTrackNotification(trackedId: String, notificationId: String) async {
        guard supports(.trackedPrs) else { return }
        connection.send(["type": "resolveTrackNotification", "trackedId": trackedId,
                         "notificationId": notificationId])
    }

    public func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void {
        guard supports(.trackedPrs) else {
            // The wire replies with the whole list on subscribe; an empty list is the
            // honest equivalent, and it keeps the panel's "nothing tracked" state right.
            onEvent(.trackedPrs([]))
            return {}
        }
        let (token, known) = lock.withLock { () -> (Int, [TrackedPr]?) in
            let t = nextListenerToken
            nextListenerToken += 1
            trackedListeners[t] = onEvent
            return (t, trackedList)
        }
        ensureTrackedSubscription()
        // Handed the current list immediately when this connection already has one.
        // When it does not, the hand-over IS the daemon's answer to the subscribe just
        // sent — the listener is already registered, so it arrives there rather than
        // being awaited here and then delivered twice.
        if let known { onEvent(.trackedPrs(known)) }
        return { [weak self] in
            guard let self else { return }
            lock.withLock { self.trackedListeners[token] = nil }
        }
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

    // MARK: - Idle reaper (capability: reaper)

    /// The Settings → Sessions idle window, over the wire.
    ///
    /// This used to be a no-op whose comment claimed the daemon owned its own reaper.
    /// It did not own one at all: nothing in `apps/juancoded` had ever set a session
    /// dormant, so on this core the stepper moved a number nothing read, no session
    /// ever slept, and 19 live CLI trees sat where the Swift core would have been
    /// reclaiming about 5.7GB. The daemon has a real reaper now (juancode-52e8.14.1)
    /// and this is the frame that steers it.
    public func setReaperIdleWindow(minutes: Int) async {
        lock.withLock { reaperWindowMinutes = minutes }
        guard sendsReaperFrames("idle window") else { return }
        connection.send(["type": "setReaperPolicy", "minutes": minutes])
    }

    /// The sessions the reaper must never sleep: the pane the user has open and the
    /// active Oracle. Replaces this connection's whole set, so an empty set clears it.
    public func setReaperProtectedIds(_ ids: Set<String>) async {
        lock.withLock { reaperProtectedIds = ids }
        guard sendsReaperFrames("never-sleep set") else { return }
        connection.send(["type": "setReaperProtectedIds", "sessionIds": Array(ids).sorted()])
    }

    /// Re-state both after a reconnect.
    ///
    /// The daemon keys the never-sleep set on the *connection* that declared it, so a
    /// reconnect arrives with nothing protected — and the app will not re-push on its
    /// own: `AppModel.applyReaperProtection` short-circuits when the set has not
    /// changed, which it has not. Without this the pane the user is looking at is
    /// reapable from the moment the socket blips, which is the one thing the set
    /// exists to prevent. The window is re-stated for the matching reason: a restarted
    /// daemon is back at its own boot default, not at the Settings value.
    private func resendReaperPolicy() {
        guard info.has("reaper") else { return }
        let (minutes, ids) = lock.withLock { (reaperWindowMinutes, reaperProtectedIds) }
        if let minutes {
            connection.send(["type": "setReaperPolicy", "minutes": minutes])
        }
        if let ids {
            connection.send(["type": "setReaperProtectedIds", "sessionIds": Array(ids).sorted()])
        }
    }

    /// Whether the connected daemon speaks the reaper frames.
    ///
    /// Checked against the raw capability string rather than a `CoreCapability` case
    /// on purpose: `reaper` names two frames, not a feature. The Swift core reaps
    /// without them because its reaper is in-process, so a `CoreCapability` case would
    /// make the capability panel report "no idle reaper" for the one core that has
    /// always had one.
    private func sendsReaperFrames(_ what: String) -> Bool {
        guard info.has("reaper") else {
            NSLog("juancode: the \(backendName) core has no reaper capability — \(what) not applied")
            return false
        }
        return true
    }

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

    func sendSleep(sessionId: String) -> Bool {
        guard info.has(Self.sessionSleepCapability) else { return false }
        connection.send(["type": "sleepSession", "sessionId": sessionId])
        return true
    }

    /// A patch, so only the fields that were given are sent: a rename must not carry
    /// an archive flag it does not know it is responsible for, and the core reads an
    /// absent field as "leave it alone".
    @discardableResult
    func sendSetMeta(sessionId: String, title: String?, archived: Bool?) -> Bool {
        guard info.has(Self.sessionEditCapability) else {
            NSLog("juancode: the \(backendName) core has no sessionEdit capability — "
                  + "\(sessionId) is renamed in the mirror only; the core keeps its own row")
            return false
        }
        var frame: [String: Any] = ["type": "setMeta", "sessionId": sessionId]
        if let title { frame["title"] = title }
        if let archived { frame["archived"] = archived }
        connection.send(frame)
        return true
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

        case "sessions":
            guard let raw = body["sessions"] as? [Any] else { return }
            backfill(raw.compactMap(Self.decodeMeta))

        case "sessionDeleted":
            guard let id = sessionId else { return }
            let tree = body["worktreePath"] as? String
            if let tree, body["worktreeRemoved"] as? Bool == false {
                // The one thing worth saying about a failed reap: the directory a
                // human now has to remove by hand.
                NSLog("juancode: the rust core could not remove \(id)'s worktree at \(tree)")
            }
            forget(id)

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
            // A refused queue write is reported as an error frame for that session, and
            // its codes are the daemon's own (`queue-item-not-found`,
            // `queue-item-not-text`, `queue-unavailable`). It belongs to the write that
            // is waiting on it and to nothing else: routed here rather than allowed to
            // fail whatever lifecycle request happens to be in flight, and consumed
            // rather than falling through, because a `queue-` code is never the answer
            // to anything but a queue frame. The frame does not say WHICH write it
            // answers, so a session with several in flight fails all of them — the safe
            // direction, since the alternative is one of them reporting a success it
            // cannot account for.
            if let id = sessionId, message.hasPrefix("queue-"),
               let refused = lock.withLock({ () -> [QueueWrite]? in
                   guard let writes = queueWrites[id], !writes.isEmpty else { return nil }
                   queueWrites[id] = nil
                   return writes
               }) {
                NSLog("juancode: the rust core refused a queue write for \(id): \(message)")
                for write in refused { write.refuse(message) }
                return
            }
            if let id = sessionId, lock.withLock({ probing.remove(id) }) != nil {
                // A probe for a session the daemon does not have: expected, and not
                // the answer to whatever lifecycle request may be in flight.
                NSLog("juancode: rust core has no session \(id) (\(message))")
                return
            }
            pendingResult { $0.failure = CoreRemoteError(message: message, sessionId: sessionId) }

        case "trackedPrs":
            let list = Self.decodeTrackedPrs(body["tracked"])
            let (listeners, waiters) = lock.withLock {
                // Written before anybody is woken: a waiter reads this cache.
                trackedList = list
                let waiting = trackedWaiters
                trackedWaiters.removeAll()
                return (Array(trackedListeners.values), waiting)
            }
            // Replace wholesale: the frame is the complete watch list and never a
            // delta, so a subscriber's whole job is to drop what it was holding.
            for l in listeners { l(.trackedPrs(list)) }
            for w in waiters { w.arrived() }

        case "trackNotification":
            guard let trackedId = body["trackedId"] as? String,
                  let prNumber = body["prNumber"] as? Int,
                  let notification = Self.decodeTrackNotification(body["notification"])
            else { return }
            for l in lock.withLock({ Array(trackedListeners.values) }) {
                l(.trackNotification(trackedId: trackedId, prNumber: prNumber,
                                     notification: notification))
            }

        case "queue":
            guard let id = sessionId else { return }
            let revision = body["revision"] as? Int ?? 0
            let items = Self.decodeQueueItems(body["items"])
            let (listeners, waiters, settled) = lock.withLock {
                () -> ([MessageQueue.Listener], [FrameWaiter], [(QueueWrite, QueuedMessage)]) in
                // A snapshot older than the one we hold is dropped whole: it is not a
                // patch, so applying it would un-do a change we have already seen. The
                // baseline comes at revision 0 for a queue nobody has written to, which
                // is why the first snapshot is taken on a missing key rather than on a
                // greater revision.
                if let seen = queueRevisions[id], revision < seen { return ([], [], []) }
                queueRevisions[id] = revision
                queueSnapshots[id] = items
                let waiting = queueFrameWaiters[id] ?? []
                queueFrameWaiters[id] = nil
                // Which in-flight writes this snapshot answers. A row answers a write
                // when it carries that write's text and is not a row the write already
                // knew about, and it answers at most one write: two identical messages
                // in flight are two rows, and each write gets its own.
                var claimed: Set<String> = []
                var answers: [(QueueWrite, QueuedMessage)] = []
                for write in queueWrites[id] ?? [] {
                    let match = items.first { item in
                        guard !claimed.contains(item.id) else { return false }
                        if let edited = write.editing {
                            return item.id == edited && item.text == write.text
                        }
                        return item.text == write.text && !write.knownIds.contains(item.id)
                    }
                    guard let match else { continue }
                    claimed.insert(match.id)
                    answers.append((write, match))
                }
                return (Array((queueListeners[id] ?? [:]).values), waiting, answers)
            }
            // Replace wholesale, exactly as for the tracked-PR list.
            for l in listeners { l(items) }
            for w in waiters { w.arrived() }
            for (write, item) in settled { write.queued(item) }

        case "inputAck", "screen", "editorReady", "terminalReady":
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
            resendReaperPolicy()
            // And re-read the list. A reconnect is a new connection to a core that
            // may have restarted, pruned or been driven by somebody else while this
            // socket was down, and every delta that happened in the gap is one this
            // client was not there to hear.
            if info.has(Self.sessionListCapability) {
                connection.send(["type": "listSessions"])
            }
            // And re-subscribe to the watch list, which is also per connection. The
            // list is dropped rather than kept across the gap: the daemon may have
            // untracked a merged PR while this socket was down, and a stale list is a
            // sidebar row for a PR nobody is watching.
            let resubscribe: Bool = lock.withLock {
                guard trackedSubscribed || !trackedListeners.isEmpty else { return false }
                trackedSubscribed = false
                trackedList = nil
                return true
            }
            if resubscribe { ensureTrackedSubscription() }
            // Same treatment for every queue subscription: per connection on the
            // daemon's side, and the cached snapshot is dropped rather than kept,
            // because the phone may have queued or the agent may have taken delivery
            // while this socket was down. A stale snapshot is worse than none — it is
            // what a write would be confirmed against.
            let queues: [String] = lock.withLock {
                let ids = Array(Set(queueSubscribed).union(queueListeners.keys))
                queueSubscribed.removeAll()
                queueSnapshots.removeAll()
                queueRevisions.removeAll()
                return ids
            }
            for id in queues { ensureQueueSubscription(id) }
        } else if let reason {
            NSLog("juancode: rust core connection lost (\(reason))")
            // Every queue write in flight fails now rather than waiting out its budget:
            // the socket that would have carried the confirmation is gone, so the write
            // is unconfirmable and the caller has to be told while the user is still
            // looking at the thing they pressed.
            let (orphaned, stranded) = lock.withLock { () -> ([QueueWrite], [FrameWaiter]) in
                let writes = queueWrites.values.flatMap { $0 }
                let waiters = queueFrameWaiters.values.flatMap { $0 }
                queueWrites.removeAll()
                queueFrameWaiters.removeAll()
                return (writes, waiters)
            }
            for write in orphaned { write.refuse("the connection dropped: \(reason)") }
            for waiter in stranded { waiter.expire() }
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

    /// Reconcile the mirror against a `sessions` snapshot: the whole list, so rows
    /// the core does not have go too.
    ///
    /// No handles and no `onSessionCreated`. A handle is a pane's live connection to
    /// a pty; the sidebar reads rows out of the mirror, and minting several hundred
    /// handles for sessions nobody has opened would announce every session in the
    /// daemon's history as newly created. A pane's handle is made when something
    /// attaches, which is where it always was.
    ///
    /// Only rows we hold no handle for are deleted. A session created on this
    /// connection a moment ago is legitimately absent from a snapshot the daemon
    /// serialised before it existed, and dropping it would be this client losing its
    /// own live session to a race it started.
    private func backfill(_ metas: [SessionMeta]) {
        let known = Set(metas.map(\.id))
        var inserted = 0
        var updated = 0
        for meta in metas {
            guard let existing = mirror.get(meta.id) else {
                mirror.insert(meta)
                inserted += 1
                continue
            }
            // The steady state after the first backfill: every row already right, so
            // a reconnect costs reads and no writes. Each write here is its own
            // transaction, and a few hundred needless ones is a visible boot pause.
            guard existing != meta else { continue }
            mirror.updateMeta(meta, reindexTitleFts: existing.title != meta.title)
            updated += 1
        }
        let live = lock.withLock { Set(handles.keys) }
        var dropped = 0
        for row in mirror.list() where !known.contains(row.id) && !live.contains(row.id) {
            if mirror.delete(row.id) { dropped += 1 }
        }
        NSLog("juancode: backfilled the rust mirror from the core — "
              + "\(metas.count) sessions listed, \(inserted) new, \(updated) refreshed, "
              + "\(dropped) dropped")
        // Whoever is waiting on boot is waiting for exactly this.
        lock.withLock { backfillWaiter }?.signal()
    }

    /// Drop everything this client holds for a session the core has forgotten.
    ///
    /// Idempotent, and called from both ends: the local delete runs it before the
    /// frame goes out, and the `sessionDeleted` broadcast runs it again when the
    /// daemon confirms. Dropping a row that is already gone is a no-op, and the
    /// alternative — only trusting the broadcast — leaves the row on screen for the
    /// round trip.
    private func forget(_ id: String) {
        let handle = lock.withLock { () -> RemoteLiveSession? in
            seedFailureReporters[id] = nil
            _ = probing.remove(id)
            return handles.removeValue(forKey: id)
        }
        // The pane is told the pty is gone, which is the truthful half of a delete it
        // can render; the row it would read back is already going.
        handle?.apply(exitCode: nil)
        _ = mirror.delete(id)
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

    /// Read a `queue` frame's rows back into `QueuedMessage`, in the order the frame
    /// carried them — which is delivery order and the only order that means anything.
    ///
    /// The wire row is richer than the struct: it also says `state` (pending or in
    /// flight), `source`, and a `kind` that may be `keys` rather than `text`. A `keys`
    /// row holds a control sequence somebody sent from another surface, and its bytes
    /// deliberately stay off the wire — so it is kept with its label as its text rather
    /// than dropped. A dropped row would make this client report a shorter queue than
    /// the core has, which is the class of lie this whole area is being fixed for.
    static func decodeQueueItems(_ raw: Any?) -> [QueuedMessage] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let text = (row["text"] as? String) ?? (row["label"] as? String) ?? ""
            return QueuedMessage(id: id, text: text,
                                 createdAt: row["createdAt"] as? Int ?? 0)
        }
    }

    /// Read the wire's tracked-PR rows back into `TrackedPr`.
    ///
    /// Hand-rolled rather than `Codable`, because the wire shape is not this struct:
    /// it carries the derived `state` and a flat `checks` where the struct keeps a
    /// whole diff baseline, and the baseline is the daemon's business — this side
    /// never diffs anything. So `checks` is put back into the snapshot it came out of
    /// and everything else is left at its default, which makes the struct's own
    /// derived `state` come out equal to the string the daemon sent: both cores derive
    /// it from the same two inputs.
    static func decodeTrackedPrs(_ raw: Any?) -> [TrackedPr] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int,
                  let cwd = row["cwd"] as? String else { return nil }
            let checks = PrChecks(rawValue: row["checks"] as? String ?? "") ?? .none
            return TrackedPr(
                number: number,
                title: row["title"] as? String ?? "",
                branch: row["branch"] as? String ?? "",
                url: row["url"] as? String ?? "",
                cwd: cwd,
                sessionId: row["sessionId"] as? String ?? "",
                snapshot: PrTrackSnapshot(checks: checks, baselined: true),
                notifications: (row["notifications"] as? [Any] ?? [])
                    .compactMap(decodeTrackNotification),
                lastPolledAt: row["lastPolledAt"] as? Int)
        }
    }

    static func decodeTrackNotification(_ raw: Any?) -> TrackNotification? {
        guard let row = raw as? [String: Any],
              let id = row["id"] as? String,
              let prNumber = row["prNumber"] as? Int,
              let message = row["message"] as? String else { return nil }
        return TrackNotification(id: id, prNumber: prNumber, message: message,
                                 createdAt: row["createdAt"] as? Int ?? 0)
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

/// A one-shot "the frame arrived, or the wait ran out" handoff.
///
/// One-shot is the whole contract: the frame and the expiry race, and the loser must
/// not be able to resume a continuation the winner already used. `DispatchSemaphore` is
/// what the lifecycle waiter beside this uses, and it cannot be: its `wait` is
/// unavailable from an async context, and the tracked-PR reads are async all the way
/// down.
/// One queue write waiting for the core's verdict.
///
/// Three answers and no fourth: the row appeared in a snapshot, the core refused it
/// with a code, or nothing came before the budget ran out. Silence is deliberately an
/// answer of its own and deliberately a failure — the bug this class exists for
/// (juancode-rzl7) was a write that reported success while the core had never heard of
/// it, so "we do not know" must never be spelled the same way as "it landed".
///
/// One-shot: whichever of the three lands first settles it, and the others are
/// no-ops, so the refusal that arrives just after a timeout cannot resume twice.
private final class QueueWrite: @unchecked Sendable {
    enum Answer {
        case queued(QueuedMessage)
        case refused(String)
        case timedOut
    }

    /// The text this write sent, which is how a snapshot's row is recognised as its
    /// answer.
    let text: String
    /// The row ids the session's queue already held when this write went out, so a row
    /// that was pending before cannot be mistaken for the row this write made.
    let knownIds: Set<String>
    /// Set for an `editQueued`, which names its row: the answer is that id carrying the
    /// new text rather than any new row.
    let editing: String?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Answer, Never>?
    private var settled: Answer?

    init(text: String, knownIds: Set<String>, editing: String? = nil) {
        self.text = text
        self.knownIds = knownIds
        self.editing = editing
    }

    func answer() async -> Answer {
        await withCheckedContinuation { c in
            let done: Answer? = lock.withLock {
                if let settled { return settled }
                continuation = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    func queued(_ item: QueuedMessage) { settle(.queued(item)) }
    func refuse(_ code: String) { settle(.refused(code)) }
    func timeOut() { settle(.timedOut) }

    private func settle(_ answer: Answer) {
        let waiting: CheckedContinuation<Answer, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = answer
            let taken = continuation
            continuation = nil
            return taken
        }
        waiting?.resume(returning: answer)
    }
}

private final class FrameWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var outcome: Bool?

    /// `true` when a frame arrived, `false` when the budget ran out.
    func landed() async -> Bool {
        await withCheckedContinuation { c in
            let settled: Bool? = lock.withLock {
                if let outcome { return outcome }
                continuation = c
                return nil
            }
            if let settled { c.resume(returning: settled) }
        }
    }

    func arrived() { settle(true) }
    func expire() { settle(false) }

    private func settle(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = value
            let taken = continuation
            continuation = nil
            return taken
        }
        waiting?.resume(returning: value)
    }
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
