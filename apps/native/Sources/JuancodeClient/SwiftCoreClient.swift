import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServer
import JuancodeServices

/// `CoreClient` over the in-process Swift core: the `SessionRegistry` that owns
/// the real ptys, the GRDB store, the message queue, the tracked-PR engine and
/// the ephemeral pty registry, all of it held together by `AppState`, which the
/// embedded WebSocket server drives from the other side.
///
/// This is the only place in the app that knows those objects exist. It adds no
/// behaviour of its own: every member forwards, so the local UI and a remote
/// client are still subscribers to one registry, with no wire hop for the local
/// view.
public final class SwiftCoreClient: CoreClient, @unchecked Sendable {
    /// The shared state the embedded server drives from the other side. Passed to
    /// `JuancodeServer.run` by `startEmbeddedServer()` and otherwise private: the
    /// UI reaches the core through the protocol.
    private let state: AppState

    /// Wrap an already-built core (tests, and the in-memory fallback below).
    public init(state: AppState) {
        self.state = state
    }

    /// Open the on-disk core. Falling back to an ephemeral in-memory store when the
    /// database won't open keeps the app usable for the launch and carries the
    /// reason, so the UI can offer to reset the file. Only failing to open even an
    /// in-memory database is fatal.
    ///
    /// `dbPath` defaults to this core's own file. One database per core is the rule
    /// that makes the backend switch safe (`CoreBoot`): two writers on one SQLite
    /// file plus two schemas drifting apart is what it exists to prevent.
    public static func local(dbPath: String = Config.databasePath(for: .swift))
        -> (core: SwiftCoreClient, degradedReason: String?, corruptDbPath: String) {
        do {
            return (SwiftCoreClient(state: try AppState(dbPath: dbPath)), nil, dbPath)
        } catch {
            NSLog("juancode: on-disk database failed to open (\(dbPath)): \(error)")
            do {
                let fallback = AppState(store: try GRDBStore(inMemory: true))
                return (SwiftCoreClient(state: fallback), String(describing: error), dbPath)
            } catch {
                fatalError("Failed to open even an in-memory database: \(error)")
            }
        }
    }

    /// Boot the embedded WS+HTTP server against this core, so remote clients attach
    /// to the same registry the local UI drives. Best-effort: a taken port leaves
    /// the local shell fully working. `handleSignals: false` so the server doesn't
    /// swallow the terminal's Ctrl-C: the app owns its own lifecycle (Cmd-Q, or
    /// Ctrl-C terminates the process).
    public func startEmbeddedServer(host: String, port: Int) {
        let state = state
        Task.detached {
            do {
                try await JuancodeServer.run(state: state, host: host, port: port,
                                             handleSignals: false)
            } catch {
                NSLog("juancode: embedded server did not start: \(error)")
            }
        }
    }

    // MARK: - Handshake

    public var info: CoreServerInfo {
        CoreServerInfo(protocolVersion: WireProtocol.version, capabilities: WireProtocol.capabilities)
    }

    // MARK: - Session lifecycle

    @discardableResult
    public func create(provider: ProviderId, cwd: String, cols: Int, rows: Int,
                       opts: SpawnOptions, worktreePath: String?,
                       dispatchId: String?) throws -> any LiveSession {
        try state.registry.create(provider: provider, cwd: cwd, cols: cols, rows: rows,
                                 opts: opts, worktreePath: worktreePath, dispatchId: dispatchId)
    }

    @discardableResult
    public func createEditorSession(parent: SessionMeta, file: String?, line: Int?,
                                    cols: Int, rows: Int) throws -> any LiveSession {
        try state.registry.createEditor(parent: parent, file: file, line: line,
                                        cols: cols, rows: rows)
    }

    @discardableResult
    public func resume(_ meta: SessionMeta, cols: Int, rows: Int,
                       priorScrollback: [UInt8]) throws -> any LiveSession {
        try state.registry.resume(meta, cols: cols, rows: rows, priorScrollback: priorScrollback)
    }

    @discardableResult
    public func restartFresh(_ meta: SessionMeta, cols: Int, rows: Int) throws -> any LiveSession {
        try state.registry.restartFresh(meta, cols: cols, rows: rows)
    }

    public func setSkipPermissions(_ sessionId: String, skipPermissions: Bool,
                                   cols: Int, rows: Int) async throws -> any LiveSession {
        try await state.registry.setSkipPermissions(sessionId, skipPermissions: skipPermissions,
                                                    cols: cols, rows: rows)
    }

    public func kill(_ sessionId: String) {
        state.registry.get(sessionId)?.kill()
    }

    // MARK: - Live sessions

    public func liveSession(_ id: String) -> (any LiveSession)? { state.registry.get(id) }

    public func liveSessions() -> [any LiveSession] { state.registry.all() }

    @discardableResult
    public func onSessionCreated(_ listener: @escaping (any LiveSession) -> Void) -> () -> Void {
        state.registry.onCreate { listener($0) }
    }

    // MARK: - Persisted sessions

    public func sessions() -> [SessionMeta] { state.store.list() }

    public func session(_ id: String) -> SessionMeta? { state.store.get(id) }

    public func insertSession(_ meta: SessionMeta) { state.store.insert(meta) }

    public func updateSession(_ meta: SessionMeta, scrollback: [UInt8]) {
        state.store.update(meta, scrollback: scrollback)
    }

    public func deleteSession(_ id: String) { _ = state.store.delete(id) }

    public func storedScrollback(_ id: String) -> [UInt8]? { state.store.getScrollback(id) }

    public func setTitle(_ id: String, title: String) { state.store.setTitle(id, title: title) }

    public func setArchived(_ id: String, archived: Bool) {
        state.store.setArchived(id, archived: archived)
    }

    public func setCliSessionId(_ id: String, cliSessionId: String) {
        state.store.setCliSessionId(id, cliSessionId: cliSessionId)
    }

    public func usedCliSessionIds() -> Set<String> { state.store.usedCliSessionIds() }

    public func searchSessions(_ query: String, limit: Int) -> [SearchHit] {
        state.store.search(query, limit: limit)
    }

    public func enforceSessionCap(projectKey: (String) -> String, keepIds: Set<String>) {
        state.store.enforceSessionCap(projectKey: projectKey, keepIds: keepIds)
    }

    public func performMaintenance() throws -> GRDBStore.MaintenanceReport {
        try state.store.performMaintenance()
    }

    // MARK: - Message queue

    @discardableResult
    public func queueMessage(_ sessionId: String, text: String) -> QueuedMessage {
        state.messageQueue.add(sessionId, text: text)
    }

    public func queuedMessages(_ sessionId: String) -> [QueuedMessage] {
        state.messageQueue.list(sessionId)
    }

    @discardableResult
    public func dequeueMessage(_ sessionId: String, messageId: String) -> Bool {
        state.messageQueue.remove(sessionId, messageId)
    }

    @discardableResult
    public func subscribeQueue(_ sessionId: String,
                               _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void {
        state.messageQueue.onChange(sessionId, listener)
    }

    // MARK: - Ephemeral ptys

    public func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty {
        try state.ephemeral.openEditor(cwd: cwd, file: file, cols: cols, rows: rows)
    }

    public func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty {
        try state.ephemeral.openTerminal(cwd: cwd, cols: cols, rows: rows)
    }

    // MARK: - Tracked PRs

    public func trackedPrs() async -> [TrackedPr] { await state.prTracking.list() }

    public func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int) async -> TrackedPr? {
        await state.prTracking.track(pr, cwd: cwd, cols: cols, rows: rows)
    }

    public func untrackPr(_ trackedId: String) async {
        await state.prTracking.untrack(trackedId)
    }

    public func resolveTrackNotification(trackedId: String, notificationId: String) async {
        await state.prTracking.resolveNotification(trackedId: trackedId,
                                                   notificationId: notificationId)
    }

    public func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void {
        await state.prTracking.subscribe { change in
            switch change {
            case .tracked(let list):
                onEvent(.trackedPrs(list))
            case let .notification(trackedId, prNumber, notification):
                onEvent(.trackNotification(trackedId: trackedId, prNumber: prNumber,
                                           notification: notification))
            }
        }
    }

    // MARK: - Launch state

    public var crashOrphanIds: Set<String> { state.crashOrphanIds }

    public var midTurnOrphanIds: Set<String> { state.midTurnOrphanIds }

    // MARK: - Presence, diagnostics, lifecycle

    public func markDesktopActive() { state.markDesktopActive() }

    public func logSessionEvent(_ event: String, sessionId: String, project: String,
                                fields: [String: String]) {
        state.activityLog.log(event, sessionId: sessionId, project: project, fields: fields)
    }

    public func flushSessionLog() -> String {
        state.activityLog.flush()
        return state.activityLog.logPath
    }

    public func setReaperIdleWindow(minutes: Int) async {
        await state.sessionReaper.setIdleWindow(minutes: minutes)
    }

    public func shutdown() { state.shutdown() }

    public func shutdownGracefully(timeout: TimeInterval) {
        state.shutdownGracefully(timeout: timeout)
    }
}
