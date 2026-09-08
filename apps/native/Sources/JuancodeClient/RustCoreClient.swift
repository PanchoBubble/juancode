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
    /// How long boot waits for the first `sessions` snapshot. Long enough for the
    /// daemon to serialise a few hundred rows, short enough that an unresponsive core
    /// costs a late sidebar rather than a launch.
    private static let backfillTimeout: TimeInterval = 5.0
    /// How long a read of the watch list waits for the daemon's answer.
    private static let trackedListTimeout: TimeInterval = 5.0
    /// How long `trackPr` waits for the PR to appear in the list. Generous, because
    /// tracking fetches a branch and boots a CLI before the row exists.
    private static let trackTimeout: TimeInterval = 45.0

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

        case "inputAck", "screen", "queue", "editorReady", "terminalReady":
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
