import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import XCTest

@testable import JuancodeClient

/// The heavy-queue surface, in the two halves that can lie independently.
///
/// The value half — ordering arithmetic and decoding — is pure and needs no socket.
/// The wire half is driven over a real socket against a stand-in daemon, because what
/// broke every time this surface moved was not a wrong number: it was a frame that
/// never went out, or a capability the app trusted and the core did not serve. The
/// registry is the CORE's now (juancode-52e8.14.3), so nothing in these tests reads
/// or writes `/tmp/claude-heavy-$UID`.
final class HeavyQueueClientTests: XCTestCase {

    // MARK: - The values the frame carries

    func testAJobDecodesWithNullsForTheFieldsAWaitingJobHasNot() throws {
        let job = try XCTUnwrap(HeavyJob(wire: [
            "pid": 4242, "prio": 3, "since": 1_758_000_000, "slot": 0,
            "cmd": "cargo build", "cwd": "/repo/pandora",
            "child": NSNull(), "started": NSNull(),
        ]))
        XCTAssertEqual(job.pid, 4242)
        XCTAssertNil(job.child)
        XCTAssertNil(job.started)
        XCTAssertFalse(job.running)
        XCTAssertEqual(job.project, "pandora")
        // And a body with no pid is not a job: the pid is the id, the filename and the
        // thing a cancel names, so a row without one is not addressable.
        XCTAssertNil(HeavyJob(wire: ["prio": 1]))
        XCTAssertNil(HeavyJob(wire: "nonsense"))
    }

    func testASnapshotTakesTheTwoListsInTheOrderTheCoreSentThem() throws {
        let snapshot = try XCTUnwrap(HeavyQueueSnapshot(wire: [
            "slots": 2, "workerCap": 6,
            "running": [["pid": 1, "slot": 1]],
            "waiting": [["pid": 2, "prio": 5], ["pid": 3]],
        ]))
        XCTAssertEqual(snapshot.slots, 2)
        XCTAssertEqual(snapshot.workerCap, 6)
        // Not re-sorted here: the core orders both lists, and a client that sorted
        // again would be a second opinion about who runs next.
        XCTAssertEqual(snapshot.waiting.map(\.pid), [2, 3])
        XCTAssertEqual(snapshot.total, 3)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertNil(HeavyQueueSnapshot(wire: ["type": "heavyQueue"]))
    }

    func testMoveToFrontBeatsTheBestQueuedPriority() {
        let queue = HeavyQueueSnapshot(waiting: [
            HeavyJob(pid: 1, prio: 4), HeavyJob(pid: 2, prio: 0),
        ])
        XCTAssertEqual(queue.moveToFrontPriority, 5)
        // And it is never 0, so "run this next" on an all-default line still moves.
        XCTAssertEqual(HeavyQueueSnapshot().moveToFrontPriority, 1)
    }

    func testNudgeStepsPastAnEqualNeighbourAndSwapsWithAHigherOne() {
        let equal = HeavyQueueSnapshot(waiting: [
            HeavyJob(pid: 1, prio: 0, since: 10), HeavyJob(pid: 2, prio: 0, since: 20),
        ])
        // Equal priorities order by age, so a swap would move nothing.
        let stepped = equal.nudgePriorities(pid: 2, up: true)
        XCTAssertEqual(stepped.map(\.pid), [2])
        XCTAssertEqual(stepped.map(\.prio), [1])

        let uneven = HeavyQueueSnapshot(waiting: [
            HeavyJob(pid: 1, prio: 5, since: 10), HeavyJob(pid: 2, prio: 1, since: 20),
        ])
        let swapped = uneven.nudgePriorities(pid: 2, up: true)
        XCTAssertEqual(swapped.map(\.pid), [2, 1])
        XCTAssertEqual(swapped.map(\.prio), [5, 1])

        // The edges and a pid that is not in the line are no-ops, not crashes.
        XCTAssertTrue(equal.nudgePriorities(pid: 1, up: true).isEmpty)
        XCTAssertTrue(equal.nudgePriorities(pid: 2, up: false).isEmpty)
        XCTAssertTrue(equal.nudgePriorities(pid: 999, up: true).isEmpty)
    }

    // MARK: - The frames

    func testSubscribingAnswersWithTheQueueAndTheMutationsGoOutAsFrames() async throws {
        let daemon = HeavyDaemon()
        try await withHeavyDaemon(daemon) { core in
            let log = HeavySnapshotLog()
            let cancel = core.subscribeHeavyQueue { log.record($0) }
            try await log.settleOnCount(1)
            XCTAssertEqual(log.snapshots.last?.waiting.map(\.pid), [10, 20])
            XCTAssertEqual(log.snapshots.last?.slots, 1)

            core.heavySetPriority(pid: 20, prio: 5)
            _ = await daemon.awaitFrame(ofType: "heavySetPriority")
            core.heavySetSlots(3)
            _ = await daemon.awaitFrame(ofType: "heavySetSlots")
            core.heavyCancel(pid: 10)
            _ = await daemon.awaitFrame(ofType: "heavyCancel")

            XCTAssertEqual(daemon.heavyFrameTypes,
                           ["heavyQueueSubscribe", "heavySetPriority", "heavySetSlots",
                            "heavyCancel"])
            XCTAssertEqual(daemon.frames(ofType: "heavySetPriority").first?["prio"] as? Int, 5)
            XCTAssertEqual(daemon.frames(ofType: "heavySetSlots").first?["slots"] as? Int, 3)
            XCTAssertEqual(daemon.frames(ofType: "heavyCancel").first?["pid"] as? Int, 10)

            // The last watcher going away tells the core to stop reading the registry.
            cancel()
            let unsubscribed = await daemon.awaitFrame(ofType: "heavyQueueUnsubscribe")
            XCTAssertNotNil(unsubscribed)
        }
    }

    func testASecondWatcherJoinsTheOneSubscriptionAndIsHandedTheQueueAtOnce() async throws {
        let daemon = HeavyDaemon()
        try await withHeavyDaemon(daemon) { core in
            let first = HeavySnapshotLog()
            let cancelFirst = core.subscribeHeavyQueue { first.record($0) }
            try await first.settleOnCount(1)

            let second = HeavySnapshotLog()
            let cancelSecond = core.subscribeHeavyQueue { second.record($0) }
            // Handed the cached queue synchronously: a second panel must not have to
            // wait out a change for its first draw.
            XCTAssertEqual(second.snapshots.count, 1)
            XCTAssertEqual(daemon.frames(ofType: "heavyQueueSubscribe").count, 1)

            // And the first cancel does not unsubscribe while the second is watching.
            cancelFirst()
            core.heavySetSlots(2)
            _ = await daemon.awaitFrame(ofType: "heavySetSlots")
            XCTAssertTrue(daemon.frames(ofType: "heavyQueueUnsubscribe").isEmpty)
            cancelSecond()
            let unsubscribed = await daemon.awaitFrame(ofType: "heavyQueueUnsubscribe")
            XCTAssertNotNil(unsubscribed)
        }
    }

    /// The capability gate, which is the failure this surface had before it moved: a
    /// core that does not read the registry must not be sent frames it will ignore,
    /// and the subscriber must still be told something rather than left waiting.
    func testACoreWithoutTheCapabilityIsSentNothingAndAnswersEmpty() async throws {
        let daemon = HeavyDaemon()
        daemon.capabilities = ["inputAck", "resizeAck", "screen"]
        try await withHeavyDaemon(daemon) { core in
            XCTAssertFalse(core.supports(.heavyQueue))
            XCTAssertNotNil(core.unavailableReason(.heavyQueue))

            let log = HeavySnapshotLog()
            _ = core.subscribeHeavyQueue { log.record($0) }
            XCTAssertEqual(log.snapshots.count, 1)
            XCTAssertTrue(try XCTUnwrap(log.snapshots.first).isEmpty)

            core.heavySetPriority(pid: 10, prio: 5)
            core.heavySetSlots(3)
            core.heavyCancel(pid: 10)
            // Nothing went out: a frame this core ignores would be a control that looks
            // like it worked.
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(daemon.heavyFrameTypes, [])
        }
    }
}

// MARK: - The stand-in daemon

/// Answers the heavy-queue frames the way `juancoded` does: a snapshot on subscribe,
/// and nothing at all for a mutation (the core answers those with the next queue,
/// which these tests do not need to model).
private final class HeavyDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    var capabilities: [String] = ["inputAck", "resizeAck", "screen", "sessionMeta",
                                  "heavyQueue"]

    var frames: [[String: Any]] { lock.withLock { received } }

    /// Only the heavy frames, in order: the client also sends handshake-time frames
    /// whose presence depends on capabilities these tests are not about.
    var heavyFrameTypes: [String] {
        frames.compactMap { $0["type"] as? String }
            .filter { $0.hasPrefix("heavy") }
    }

    func frames(ofType type: String) -> [[String: Any]] {
        frames.filter { $0["type"] as? String == type }
    }

    /// Wait for a frame to be recorded: every mutation here is fire-and-forget, so it
    /// is written to the socket after the call has already returned.
    func awaitFrame(ofType type: String) async -> [String: Any]? {
        for _ in 0..<50 {
            if let frame = frames(ofType: type).first { return frame }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    func replies(to frame: [String: Any]) -> [String] {
        lock.withLock { received.append(frame) }
        guard frame["type"] as? String == "heavyQueueSubscribe" else { return [] }
        return [heavyJSON([
            "type": "heavyQueue", "slots": 1, "workerCap": 4,
            "running": [],
            "waiting": [
                ["pid": 10, "prio": 0, "since": 100, "slot": 0,
                 "cmd": "cargo build", "cwd": "/repo/pandora"],
                ["pid": 20, "prio": 0, "since": 200, "slot": 0,
                 "cmd": "cargo build", "cwd": "/repo/juancode"],
            ],
        ])]
    }
}

/// Every queue a subscriber was handed, in order.
private final class HeavySnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HeavyQueueSnapshot] = []

    func record(_ snapshot: HeavyQueueSnapshot) { lock.withLock { stored.append(snapshot) } }
    var snapshots: [HeavyQueueSnapshot] { lock.withLock { stored } }

    /// Wait until at least `count` have landed, so an assertion is not racing the bus.
    func settleOnCount(_ count: Int) async throws {
        for _ in 0..<50 where snapshots.count < count {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }
}

private func heavyJSON(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func makeHeavyApplication(_ daemon: HeavyDaemon) -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/ws") { inbound, outbound, _ in
        try await outbound.writeTextMessage(heavyJSON([
            "type": "serverInfo", "protocolVersion": 1, "clientId": "test-client",
            "capabilities": daemon.capabilities,
        ]))
        for try await message in inbound.messages(maxSize: 1 << 20) {
            guard case .text(let text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for line in daemon.replies(to: frame) { try await outbound.writeTextMessage(line) }
        }
    }
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "heavy-daemon"))
}

private func withHeavyDaemon(
    _ daemon: HeavyDaemon,
    _ body: @escaping @Sendable (RustCoreClient) async throws -> Void
) async throws {
    let mirrorPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("juancode-heavy-\(UUID().uuidString).db")
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }
    try await makeHeavyApplication(daemon).test(.live) { client in
        let port = try XCTUnwrap(client.port)
        let core = try await Task.detached {
            // `localhost` and not `127.0.0.1`: Hummingbird's live test server binds the
            // name, and on a machine whose `localhost` resolves to ::1 first a client
            // asking for the v4 literal is refused by a server that is up and listening.
            try RustCoreClient.connect(baseURL: "http://localhost:\(port)",
                                       mirrorPath: mirrorPath, timeout: 5)
        }.value
        defer { core.shutdown() }
        try await body(core)
    }
}
