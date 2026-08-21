import XCTest
import JuancodeCore
import JuancodePersistence
import JuancodeServer
@testable import JuancodeClient

/// `SwiftCoreClient` is the in-process implementation of `CoreClient`: it adds no
/// behaviour, so what is worth pinning is that each member reaches the piece of
/// the core it claims to (store, message queue, presence, capability handshake)
/// and that the seam's own translations (the tracked-PR event, the store's
/// discarded return values) match the wire vocabulary.
///
/// The pty-spawning members are deliberately not exercised: they would launch a
/// real CLI, which is the headless smoke's job.
final class SwiftCoreClientTests: XCTestCase {
    private var dbPath: String!
    private var core: SwiftCoreClient!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-client-\(UUID().uuidString).db")
        core = SwiftCoreClient(state: try AppState(dbPath: dbPath))
    }

    override func tearDownWithError() throws {
        core = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func meta(_ id: String, title: String = "Claude · work",
                      cwd: String = "/tmp") -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: cwd, title: title, status: .exited,
                    exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(),
                    cliSessionId: "cli-\(id)", skipPermissions: false,
                    worktreePath: nil, usage: nil)
    }

    // MARK: - Handshake

    /// The version and capability list the UI feature-detects on are the ones the
    /// wire advertises, not a second copy that can drift from it.
    func testInfoReportsTheWireHandshake() {
        XCTAssertEqual(core.info.protocolVersion, WireProtocol.version)
        XCTAssertEqual(core.info.capabilities, WireProtocol.capabilities)
        for capability in ["queue", "trackedPrs", "editor", "terminal", "adoptExternal",
                           "inputAck", "resizeAck", "screen"] {
            XCTAssertTrue(core.info.has(capability), capability)
        }
        XCTAssertFalse(core.info.has("structured"))
    }

    // MARK: - Persisted sessions

    func testPersistedSessionRoundTrip() throws {
        XCTAssertTrue(core.sessions().isEmpty)
        core.insertSession(meta("a"))
        XCTAssertEqual(core.sessions().map(\.id), ["a"])
        XCTAssertEqual(core.session("a")?.title, "Claude · work")
        XCTAssertNil(core.session("missing"))

        core.setTitle("a", title: "renamed")
        XCTAssertEqual(core.session("a")?.title, "renamed")

        core.setArchived("a", archived: true)
        XCTAssertEqual(core.session("a")?.archived, true)

        core.setCliSessionId("a", cliSessionId: "recovered")
        XCTAssertEqual(core.session("a")?.cliSessionId, "recovered")
        XCTAssertEqual(core.usedCliSessionIds(), ["recovered"])

        core.updateSession(meta("a"), scrollback: Array("hello".utf8))
        XCTAssertEqual(core.storedScrollback("a").map { String(decoding: $0, as: UTF8.self) }, "hello")

        core.deleteSession("a")
        XCTAssertTrue(core.sessions().isEmpty)
        XCTAssertNil(core.storedScrollback("a"))
    }

    func testSearchFindsAPersistedSessionByTitle() {
        core.insertSession(meta("a", title: "wire protocol seam"))
        core.insertSession(meta("b", title: "something else"))
        XCTAssertEqual(core.searchSessions("seam", limit: 10).map(\.meta.id), ["a"])
    }

    /// The seam forwards without a `perProject` override, so the cap keeps reading
    /// `Config.sessionsPerProjectCap`, off by default, and off means nothing is
    /// deleted even when every row lands in one bucket.
    func testEnforceSessionCapHonoursTheConfiguredCap() {
        for i in 0..<3 { core.insertSession(meta("s\(i)", cwd: "/tmp/project")) }
        core.enforceSessionCap(projectKey: { _ in "one-bucket" }, keepIds: ["s0"])
        XCTAssertEqual(Set(core.sessions().map(\.id)), ["s0", "s1", "s2"])
    }

    func testMaintenanceReportsOnTheRealStore() throws {
        core.insertSession(meta("a"))
        let report = try core.performMaintenance()
        XCTAssertGreaterThan(report.pageCountAfter, 0)
    }

    // MARK: - Message queue

    func testQueueOpsReachTheSameQueue() {
        let queued = core.queueMessage("s1", text: "ship it")
        XCTAssertEqual(core.queuedMessages("s1").map(\.text), ["ship it"])
        XCTAssertTrue(core.dequeueMessage("s1", messageId: queued.id))
        XCTAssertTrue(core.queuedMessages("s1").isEmpty)
        XCTAssertFalse(core.dequeueMessage("s1", messageId: queued.id))
    }

    func testQueueSubscriberSeesEveryChange() {
        let seen = QueueRecorder()
        let cancel = core.subscribeQueue("s1") { items in seen.record(items.map(\.text)) }
        core.queueMessage("s1", text: "one")
        core.queueMessage("s1", text: "two")
        cancel()
        core.queueMessage("s1", text: "after cancel")
        XCTAssertEqual(seen.snapshots(), [["one"], ["one", "two"]])
    }

    // MARK: - Live sessions

    /// Nothing was spawned, so the live half of the seam is empty rather than
    /// falling back to the persisted rows.
    func testLiveSessionsAreEmptyWithoutAPty() {
        core.insertSession(meta("a"))
        XCTAssertNil(core.liveSession("a"))
        XCTAssertTrue(core.liveSessions().isEmpty)
        core.kill("a") // no-op, not a crash
    }

    // MARK: - Tracked PRs

    /// Subscribing hands over the current watch list immediately, the same way the
    /// wire replies to `subscribeTrackedPrs`.
    func testTrackedPrSubscriptionDeliversTheSnapshot() async {
        let events = TrackedPrRecorder()
        let cancel = await core.subscribeTrackedPrs { events.record($0) }
        XCTAssertEqual(events.trackedCount(), 1)
        let list = await core.trackedPrs()
        XCTAssertTrue(list.isEmpty)
        cancel()
    }

}

/// Collects queue snapshots from the (non-main-actor) listener.
private final class QueueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []

    func record(_ texts: [String]) {
        lock.lock(); defer { lock.unlock() }
        seen.append(texts)
    }

    func snapshots() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

/// Counts `trackedPrs` events delivered to a subscriber.
private final class TrackedPrRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var tracked = 0

    func record(_ event: TrackedPrEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .trackedPrs = event { tracked += 1 }
    }

    func trackedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return tracked
    }
}
