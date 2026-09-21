import XCTest
import JuancodeCore
import JuancodePersistence
import JuancodeServer
@testable import JuancodeClient

/// What a launch connects to, which database it mirrors into, what happens when
/// the daemon is not there, and how an affordance backed by a capability the
/// connected core lacks is supposed to read.
///
/// There used to be a backend switch here — persisted setting, `JUANCODE_CORE`
/// override, requested-vs-active, fallback to the in-process core. juancode-nqpm
/// deleted the Swift core and all of it with them; what remains is one connection
/// that either lands or is refused out loud.
///
/// Deliberately no real daemon in the boot tests: the builder is injected, so what
/// is under test is the decision, not SQLite. The unreachable-core test does open a
/// real socket, at a port nothing is listening on, because "the daemon is not
/// there" is the path that has to fail loudly and a mock cannot prove that.
final class CoreBackendTests: XCTestCase {

    // MARK: - One database, and it is a mirror

    /// The mirror is NOT the daemon's own store: `juancoded` keeps that under its
    /// own data dir and is its only writer (juancode-52e8.6 / commit 007b93f).
    func testTheMirrorIsNotTheDaemonsOwnStore() {
        let mirror = Config.mirrorDatabasePath
        XCTAssertTrue(mirror.hasSuffix("/juancode-rust.db"), mirror)
        XCTAssertFalse(mirror.contains("rust-core"), mirror)
        XCTAssertFalse(mirror.hasSuffix("juancoded-rust.db"), mirror)
    }

    // MARK: - Boot

    func testBootConnectsToTheDaemonAndSaysWhereItIs() throws {
        let booted = try CoreBoot.connect(rustCoreURL: "http://127.0.0.1:4290",
                                          makeRust: { _ in FakeCore(capabilities: ["inputAck"]) })
        XCTAssertEqual(booted.selection.rustCoreURL, "http://127.0.0.1:4290")
        XCTAssertEqual(booted.selection.databasePath, Config.mirrorDatabasePath)
        XCTAssertFalse(booted.selection.daemonIsStale)
    }

    /// The whole point of deleting the second core: there is nothing to fall back
    /// to, so an unreachable daemon has to reach the caller as an error carrying the
    /// daemon's own reason. A `BootedCore` that answered nothing would be a window
    /// with no ptys, no rows and no history in it.
    func testAnUnreachableDaemonThrowsRatherThanDegrading() {
        XCTAssertThrowsError(
            try CoreBoot.connect(rustCoreURL: "http://127.0.0.1:1",
                                 makeRust: Self.refusingRust)) { error in
            let described = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertEqual(described, "No serverInfo handshake from http://127.0.0.1:1 within 200ms")
        }
    }

    // MARK: - Tracked PRs over the wire

    /// The wire's tracked-PR row is not this struct, and the gap is where a client
    /// gets it wrong: the daemon sends the DERIVED `state` and a flat `checks`, while
    /// `TrackedPr` keeps a whole diff baseline and derives `state` from it. So the
    /// decode has to put `checks` back where it came from, or every row a rust core
    /// reports reads as "watching" however red its CI is.
    func testTheWireTrackedPrRowDecodesBackIntoADerivableRow() {
        let rows: [[String: Any]] = [
            [
                "id": "/w/repo#4242",
                "number": 4242,
                "title": "conformance fixture PR",
                "branch": "main",
                "url": "https://example.invalid/pr/4242",
                "cwd": "/w/repo",
                "sessionId": "s-1",
                "state": "fixing",
                "checks": "failing",
                "notifications": [],
                "lastPolledAt": 1_700_000_000_000,
            ],
            [
                "id": "/w/repo#99",
                "number": 99,
                "title": "needs a human",
                "branch": "feature",
                "url": "https://example.invalid/pr/99",
                "cwd": "/w/repo",
                "sessionId": NSNull(),
                "state": "needs_decision",
                "checks": "passing",
                "notifications": [
                    ["id": "n-1", "prNumber": 99, "message": "@somebody requested changes",
                     "createdAt": 5],
                ],
            ],
        ]
        let decoded = RustCoreClient.decodeTrackedPrs(rows)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, "/w/repo#4242", "the id is the cwd#number key, not a field")
        XCTAssertEqual(decoded[0].sessionId, "s-1")
        XCTAssertEqual(decoded[0].snapshot.checks, .failing)
        XCTAssertEqual(decoded[0].state, .fixing, "derived, and it has to match what the core sent")
        XCTAssertEqual(decoded[0].lastPolledAt, 1_700_000_000_000)

        XCTAssertEqual(decoded[1].sessionId, "", "a null session is empty, not a dropped row")
        XCTAssertEqual(decoded[1].notifications.map(\.message), ["@somebody requested changes"])
        XCTAssertEqual(decoded[1].state, .needsDecision, "an open decision outranks green CI")
        XCTAssertNil(decoded[1].lastPolledAt, "never polled is absent, not zero")
    }

    /// A row missing what a watch IS gets dropped, and a row with an unknown `checks`
    /// spelling is kept: a newer core's colour must not cost the client the whole list.
    func testAnUnreadableTrackedPrRowIsDroppedRatherThanFatal() {
        let decoded = RustCoreClient.decodeTrackedPrs([
            ["number": 1, "cwd": "/w/repo", "checks": "something-new"],
            ["cwd": "/w/repo"],
            ["number": 2],
        ])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].snapshot.checks, .none)
        XCTAssertEqual(decoded[0].state, .watching)
        XCTAssertTrue(RustCoreClient.decodeTrackedPrs("not a list").isEmpty)
        XCTAssertNil(RustCoreClient.decodeTrackNotification(["id": "n-1"]))
    }

    // MARK: - Capability gating

    /// What the rust daemon advertises as of 2026-08-21, measured against a booted
    /// one (`RustCoreLiveTests`): the ones it does not advertise are the affordances
    /// the UI has to gate. `sessionMeta` and `gridOwner` were in that list until
    /// juancode-5k3i landed them, which is exactly why the gating reads the
    /// handshake instead of a hard-coded backend name: this list will keep
    /// shrinking without any of the call sites changing. `restartFresh` and
    /// `spawnModel` join it the other way round: the frames exist in the spec now,
    /// and the daemon is honestly silent about them until it implements them.
    /// `isolateWorktree` went the shrinking way on 2026-08-29 (juancode-yiho): the
    /// daemon now makes the worktree itself, so the toggle is no longer gated off it.
    func testTheRustDaemonsCapabilitySetGatesTheAffordancesItLacks() {
        let core = FakeCore(capabilities: ["inputAck", "resizeAck", "screen", "adoptExternal",
                                           "sessionMeta", "gridOwner", "isolateWorktree"])
        XCTAssertEqual(core.missingCapabilities,
                       [.queue, .trackedPrs, .trackPrInSession, .prWebhook, .editor,
                        .terminal, .restartFresh, .spawnModel, .spawnPreset, .heavyQueue,
                        .changes, .github])
        for capability in core.missingCapabilities {
            XCTAssertNotNil(core.unavailableReason(capability), capability.rawValue)
            XCTAssertFalse(core.supports(capability), capability.rawValue)
        }
        for capability: CoreCapability in [.inputAck, .resizeAck, .screen, .adoptExternal,
                                           .sessionMeta, .gridOwner] {
            XCTAssertTrue(core.supports(capability), capability.rawValue)
            XCTAssertNil(core.unavailableReason(capability), capability.rawValue)
        }
    }

    /// A leaner core still gates cleanly: nothing in the gating knows which core it
    /// is talking to, only what the handshake said.
    func testAMinimalCoreGatesEverythingElse() {
        let core = FakeCore(capabilities: ["inputAck", "resizeAck", "screen"])
        XCTAssertEqual(core.missingCapabilities,
                       [.queue, .trackedPrs, .trackPrInSession, .prWebhook, .editor,
                        .terminal, .adoptExternal, .sessionMeta, .gridOwner,
                        .restartFresh, .spawnModel, .spawnPreset, .isolateWorktree,
                        .heavyQueue, .changes, .github])
    }

    /// The bug this closes, and the only reason the `changes` surface is spelled as
    /// protocol REQUIREMENTS rather than left in the extension beside its defaults.
    ///
    /// A member that exists only in a protocol extension is dispatched statically: a
    /// call through `any CoreClient` binds to the extension's default at compile time
    /// and never reaches the conforming type's own version. The whole working-tree
    /// surface would have been silently dead on every core that implements it, with
    /// the panel drawing "this core cannot read the tree" against a core that can.
    ///
    /// This asserts it the only way that is meaningful: through an EXISTENTIAL, which
    /// is what `AppModel.core` is.
    func testTheChangesSurfaceDispatchesDynamicallyThroughTheExistential() async throws {
        let core: any CoreClient = AnsweringCore()
        let diff = try await core.diff(cwd: "/repo")
        XCTAssertTrue(diff.git, "a static bind would have thrown the capability default instead")
        let state = try await core.gitState(cwd: "/repo")
        XCTAssertEqual(state.branch, "main")
        let committed = try await core.commitAll(sessionId: "s1", cwd: nil, message: "m")
        XCTAssertEqual(committed.sha, "abc1234")

        // And the default is what a core WITHOUT the capability answers, through the
        // same existential: a refusal that names the capability, not an empty diff.
        let silent: any CoreClient = FakeCore(capabilities: [])
        do {
            _ = try await silent.diff(cwd: "/repo")
            XCTFail("a core with no `changes` capability must refuse rather than answer")
        } catch let error as CoreCapabilityError {
            XCTAssertEqual(error.capability, .changes)
        }
    }

    /// The error a caller that got past a gate sees: it names the capability and
    /// carries the same consequence sentence the disabled control shows, so a log
    /// line and a tooltip cannot tell different stories.
    func testCapabilityErrorCarriesTheSameReasonTheUiShows() {
        let error = CoreCapabilityError(.queue, backend: "rust")
        let text = try? XCTUnwrap(error.errorDescription)
        XCTAssertTrue(text?.contains("rust") == true, text ?? "")
        XCTAssertTrue(text?.contains(CoreCapability.queue.degradation) == true, text ?? "")
    }

    // MARK: - The unreachable daemon, for real

    /// No mock: a socket to a port nothing is listening on. The handshake wait has
    /// to end in a thrown error rather than a hang or a half-built client, because
    /// that is what `CoreBoot` turns into the refusal the launch shows.
    func testConnectingToANonListeningPortThrows() {
        // Port 1 needs no privileges to CONNECT to and nothing listens there.
        let mirrorPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-rust-mirror-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: mirrorPath + suffix) }
        }
        XCTAssertThrowsError(try RustCoreClient.connect(baseURL: "http://127.0.0.1:1",
                                                        mirrorPath: mirrorPath,
                                                        timeout: 0.6)) { error in
            let described = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(described.contains("127.0.0.1:1"), described)
        }
    }

    /// The one URL translation the client does, including the https → wss case a
    /// tunnelled daemon needs.
    func testWebsocketURLDerivation() throws {
        XCTAssertEqual(try WireConnection.websocketURL(base: "http://127.0.0.1:4290").absoluteString,
                       "ws://127.0.0.1:4290/ws")
        XCTAssertEqual(try WireConnection.websocketURL(base: "https://core.example.com").absoluteString,
                       "wss://core.example.com/ws")
        XCTAssertEqual(try WireConnection.websocketURL(base: "ws://host:9/anything").absoluteString,
                       "ws://host:9/ws")
        XCTAssertThrowsError(try WireConnection.websocketURL(base: "ftp://host"))
    }

    // MARK: - Doubles

    /// Stands in for a daemon that is not there, with the same error the real
    /// handshake wait throws.
    private static func refusingRust(_ url: String) throws -> any CoreClient {
        throw WireConnection.ConnectError.timedOut(seconds: 0.2, url: url)
    }
}

/// A `FakeCore` that answers the three working-tree members the dispatch test asks
/// for. Its whole purpose is to be a DIFFERENT answer from the protocol extension's
/// default, so a static bind is visible as a thrown capability error.
final class AnsweringCore: CoreClient, @unchecked Sendable {
    private let inner = FakeCore(capabilities: ["changes"])
    var info: CoreServerInfo { inner.info }
    var globalPause: GlobalPauseBook { inner.globalPause }

    func diff(cwd: String) async throws -> DiffResult {
        DiffResult(git: true, root: cwd, files: [])
    }
    func gitState(cwd: String) async throws -> GitState {
        GitState(git: true, branch: "main", detached: false, upstream: nil,
                 ahead: 0, behind: 0, dirty: false, remote: false)
    }
    func commitAll(sessionId: String, cwd: String?, message: String) async throws -> CommitResult {
        CommitResult(sha: "abc1234", subject: message)
    }

    // Everything else is the stand-in's, which traps.
    func create(provider: ProviderId, cwd: String, cols: Int, rows: Int, opts: SpawnOptions,
                worktree: SessionWorktree?, dispatchId: String?, initialInput: String?,
                onSeedFailure: (@Sendable (String, String) -> Void)?) throws -> any LiveSession {
        try inner.create(provider: provider, cwd: cwd, cols: cols, rows: rows, opts: opts,
                         worktree: worktree, dispatchId: dispatchId, initialInput: initialInput,
                         onSeedFailure: onSeedFailure)
    }
    func createEditorSession(parent: SessionMeta, file: String?, line: Int?, cols: Int,
                             rows: Int) throws -> any LiveSession {
        try inner.createEditorSession(parent: parent, file: file, line: line, cols: cols, rows: rows)
    }
    func resume(_ meta: SessionMeta, cols: Int, rows: Int,
                priorScrollback: [UInt8]) throws -> any LiveSession {
        try inner.resume(meta, cols: cols, rows: rows, priorScrollback: priorScrollback)
    }
    func restartFresh(_ meta: SessionMeta, cols: Int, rows: Int) throws -> any LiveSession {
        try inner.restartFresh(meta, cols: cols, rows: rows)
    }
    func setSkipPermissions(_ sessionId: String, skipPermissions: Bool, cols: Int,
                            rows: Int) async throws -> any LiveSession {
        try await inner.setSkipPermissions(sessionId, skipPermissions: skipPermissions,
                                           cols: cols, rows: rows)
    }
    func kill(_ sessionId: String) { inner.kill(sessionId) }
    func liveSession(_ id: String) -> (any LiveSession)? { inner.liveSession(id) }
    func liveSessions() -> [any LiveSession] { inner.liveSessions() }
    func onSessionCreated(_ listener: @escaping (any LiveSession) -> Void) -> () -> Void {
        inner.onSessionCreated(listener)
    }
    func sessions() -> [SessionMeta] { inner.sessions() }
    func session(_ id: String) -> SessionMeta? { inner.session(id) }
    func insertSession(_ meta: SessionMeta) { inner.insertSession(meta) }
    func updateSession(_ meta: SessionMeta, scrollback: [UInt8]) {
        inner.updateSession(meta, scrollback: scrollback)
    }
    func deleteSession(_ id: String) { inner.deleteSession(id) }
    func storedScrollback(_ id: String) -> [UInt8]? { inner.storedScrollback(id) }
    func setTitle(_ id: String, title: String) { inner.setTitle(id, title: title) }
    func setArchived(_ id: String, archived: Bool) { inner.setArchived(id, archived: archived) }
    func setCliSessionId(_ id: String, cliSessionId: String) {
        inner.setCliSessionId(id, cliSessionId: cliSessionId)
    }
    func usedCliSessionIds() -> Set<String> { inner.usedCliSessionIds() }
    func searchSessions(_ query: String, limit: Int) -> [SearchHit] {
        inner.searchSessions(query, limit: limit)
    }
    func enforceSessionCap(projectKey: (String) -> String, keepIds: Set<String>) {
        inner.enforceSessionCap(projectKey: projectKey, keepIds: keepIds)
    }
    func performMaintenance() throws -> GRDBStore.MaintenanceReport { try inner.performMaintenance() }
    func queueMessage(_ sessionId: String, text: String) -> QueuedMessage {
        inner.queueMessage(sessionId, text: text)
    }
    func queuedMessages(_ sessionId: String) -> [QueuedMessage] { inner.queuedMessages(sessionId) }
    func dequeueMessage(_ sessionId: String, messageId: String) -> Bool {
        inner.dequeueMessage(sessionId, messageId: messageId)
    }
    func subscribeQueue(_ sessionId: String,
                        _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void {
        inner.subscribeQueue(sessionId, listener)
    }
    func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty {
        try inner.openEditorPty(cwd: cwd, file: file, cols: cols, rows: rows)
    }
    func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty {
        try inner.openTerminalPty(cwd: cwd, cols: cols, rows: rows)
    }
    func trackedPrs() async -> [TrackedPr] { await inner.trackedPrs() }
    func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int,
                 adoptSessionId: String?) async -> TrackedPr? {
        await inner.trackPr(pr, cwd: cwd, cols: cols, rows: rows, adoptSessionId: adoptSessionId)
    }
    func untrackPr(_ trackedId: String) async { await inner.untrackPr(trackedId) }
    func resolveTrackNotification(trackedId: String, notificationId: String) async {
        await inner.resolveTrackNotification(trackedId: trackedId, notificationId: notificationId)
    }
    func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void {
        await inner.subscribeTrackedPrs(onEvent)
    }
    var crashOrphanIds: Set<String> { inner.crashOrphanIds }
    var midTurnOrphanIds: Set<String> { inner.midTurnOrphanIds }
    func markDesktopActive() { inner.markDesktopActive() }
    func logSessionEvent(_ event: String, sessionId: String, project: String,
                         fields: [String: String]) {
        inner.logSessionEvent(event, sessionId: sessionId, project: project, fields: fields)
    }
    func flushSessionLog() -> String { inner.flushSessionLog() }
    func setReaperIdleWindow(minutes: Int) async { await inner.setReaperIdleWindow(minutes: minutes) }
    func setReaperProtectedIds(_ ids: Set<String>) async { await inner.setReaperProtectedIds(ids) }
    func shutdown() { inner.shutdown() }
    func shutdownGracefully(timeout: TimeInterval) { inner.shutdownGracefully(timeout: timeout) }
}

/// A `CoreClient` that exists only to carry a capability list. Every member that
/// would need a core traps: reaching one from a capability test is a test bug.
final class FakeCore: CoreClient, @unchecked Sendable {
    let info: CoreServerInfo
    // Real, not a trap: the book is state a caller reads, not a core round trip.
    let globalPause = GlobalPauseBook(storage: .memory())

    init(capabilities: [String], daemon: DaemonIdentity? = nil) {
        self.info = CoreServerInfo(protocolVersion: WireProtocol.version,
                                   capabilities: capabilities, daemon: daemon)
    }

    private func unreached(_ member: String = #function) -> Never {
        XCTFail("FakeCore.\(member) should not be reached")
        fatalError(member)
    }

    func create(provider: ProviderId, cwd: String, cols: Int, rows: Int, opts: SpawnOptions,
                worktree: SessionWorktree?, dispatchId: String?, initialInput: String?,
                onSeedFailure: (@Sendable (String, String) -> Void)?) throws -> any LiveSession { unreached() }
    func createEditorSession(parent: SessionMeta, file: String?, line: Int?, cols: Int,
                             rows: Int) throws -> any LiveSession { unreached() }
    func resume(_ meta: SessionMeta, cols: Int, rows: Int,
                priorScrollback: [UInt8]) throws -> any LiveSession { unreached() }
    func restartFresh(_ meta: SessionMeta, cols: Int, rows: Int) throws -> any LiveSession { unreached() }
    func setSkipPermissions(_ sessionId: String, skipPermissions: Bool, cols: Int,
                            rows: Int) async throws -> any LiveSession { unreached() }
    func kill(_ sessionId: String) {}
    func liveSession(_ id: String) -> (any LiveSession)? { nil }
    func liveSessions() -> [any LiveSession] { [] }
    func onSessionCreated(_ listener: @escaping (any LiveSession) -> Void) -> () -> Void { {} }
    func sessions() -> [SessionMeta] { [] }
    func session(_ id: String) -> SessionMeta? { nil }
    func insertSession(_ meta: SessionMeta) {}
    func updateSession(_ meta: SessionMeta, scrollback: [UInt8]) {}
    func deleteSession(_ id: String) {}
    func storedScrollback(_ id: String) -> [UInt8]? { nil }
    func setTitle(_ id: String, title: String) {}
    func setArchived(_ id: String, archived: Bool) {}
    func setCliSessionId(_ id: String, cliSessionId: String) {}
    func usedCliSessionIds() -> Set<String> { [] }
    func searchSessions(_ query: String, limit: Int) -> [SearchHit] { [] }
    func enforceSessionCap(projectKey: (String) -> String, keepIds: Set<String>) {}
    func performMaintenance() throws -> GRDBStore.MaintenanceReport { unreached() }
    func queueMessage(_ sessionId: String, text: String) -> QueuedMessage { QueuedMessage(text: text) }
    func queuedMessages(_ sessionId: String) -> [QueuedMessage] { [] }
    func dequeueMessage(_ sessionId: String, messageId: String) -> Bool { false }
    func subscribeQueue(_ sessionId: String,
                        _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void { {} }
    func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty { unreached() }
    func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty { unreached() }
    func trackedPrs() async -> [TrackedPr] { [] }
    func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int,
                 adoptSessionId: String?) async -> TrackedPr? { nil }
    func untrackPr(_ trackedId: String) async {}
    func resolveTrackNotification(trackedId: String, notificationId: String) async {}
    func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void { {} }
    var crashOrphanIds: Set<String> { [] }
    var midTurnOrphanIds: Set<String> { [] }
    func markDesktopActive() {}
    func logSessionEvent(_ event: String, sessionId: String, project: String,
                         fields: [String: String]) {}
    func flushSessionLog() -> String { "" }
    func setReaperIdleWindow(minutes: Int) async {}
    func setReaperProtectedIds(_ ids: Set<String>) async {}
    func shutdown() {}
    func shutdownGracefully(timeout: TimeInterval) {}
}
