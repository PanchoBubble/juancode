import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import JuancodeCore
import XCTest

@testable import JuancodeClient

/// `RustCoreClient`'s queue frames, over a real socket against a stand-in daemon that
/// answers them the way `juancoded` does.
///
/// The bug these exist for (juancode-rzl7) was not a wrong value. `queueMessage` logged
/// a line and handed back a `QueuedMessage` nobody held, `queuedMessages` answered `[]`,
/// `dequeueMessage` answered `false` and the `queue` frame was explicitly ignored — and
/// because the daemon DOES advertise the `queue` capability, every UI gate passed and
/// the drop happened one line later. "Send to agent" returned focus, "Submit review"
/// archived the comments, and the agent received nothing.
///
/// So the assertions are in two halves, and the second half is the one that matters:
///
/// 1. The frames work. A write reaches the daemon, the snapshot comes back, and the row
///    the caller is handed is the DAEMON's row — its id, not one this client minted.
/// 2. A write that did not happen fails. Refused, unanswered, its subscription
///    unanswered, its socket dropped, or a capability that is not there: five different
///    silences, five thrown errors, and no caller that could mistake one of them for a
///    receipt.
final class RustCoreClientTests: XCTestCase {

    // MARK: - The write reaches the core

    /// The happy path, and the shape of it: subscribe first, then write. The
    /// subscription has to be in place before the frame goes out or there is no
    /// snapshot to confirm against — the daemon only pushes to connections that asked.
    func testAQueuedMessageIsConfirmedByTheRowTheCoreMinted() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            let item = try await core.queueMessageConfirmed("s-1", text: "run the tests")
            // The daemon mints `q-1`; a client-side UUID here would mean the caller is
            // holding an id the core has never heard of, which is what it used to get.
            XCTAssertEqual(item.id, "q-1")
            XCTAssertEqual(item.text, "run the tests")
            XCTAssertEqual(daemon.queueFrameTypes, ["subscribeQueue", "queueMessage"])
            XCTAssertEqual(daemon.frames(ofType: "queueMessage").first?["text"] as? String,
                           "run the tests")
            // And the snapshot is cached, so the queue is readable without a round trip.
            XCTAssertEqual(core.queuedMessages("s-1").map(\.text), ["run the tests"])
        }
    }

    /// Two writes in a row: the second must not confirm on the first one's row, and the
    /// subscription is not sent twice.
    func testASecondWriteConfirmsOnItsOwnRow() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            let first = try await core.queueMessageConfirmed("s-1", text: "first")
            let second = try await core.queueMessageConfirmed("s-1", text: "second")
            XCTAssertEqual(first.id, "q-1")
            XCTAssertEqual(second.id, "q-2")
            XCTAssertEqual(daemon.queueFrameTypes,
                           ["subscribeQueue", "queueMessage", "queueMessage"])
            XCTAssertEqual(core.queuedMessages("s-1").map(\.text), ["first", "second"])
        }
    }

    /// Two writes of the SAME text, which is the case a text match alone would get
    /// wrong: each confirms on a row of its own rather than both taking the first.
    func testTwoIdenticalMessagesGetOneRowEach() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            let first = try await core.queueMessageConfirmed("s-1", text: "again")
            let second = try await core.queueMessageConfirmed("s-1", text: "again")
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertEqual(core.queuedMessages("s-1").map(\.id), [first.id, second.id])
        }
    }

    /// A snapshot is the whole queue and never a patch, so a subscriber's job is to
    /// drop what it was holding — including down to nothing.
    func testSnapshotsReachSubscribersAndReplaceWholesale() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            let seen = SnapshotLog()
            let cancel = core.subscribeQueue("s-1") { seen.record($0.map(\.text)) }
            defer { cancel() }
            _ = try await core.queueMessageConfirmed("s-1", text: "one")
            _ = try await core.queueMessageConfirmed("s-1", text: "two")
            XCTAssertTrue(core.dequeueMessage("s-1", messageId: "q-1"))
            try await seen.settle(on: ["two"])
            XCTAssertEqual(seen.lists, [[], ["one"], ["one", "two"], ["two"]])
            XCTAssertEqual(core.queuedMessages("s-1").map(\.text), ["two"])
        }
    }

    /// A cancel for a row this connection has never been told about cannot claim the
    /// row was there — the Bool is about the cache, and the frame still goes out.
    func testDequeueOfAnUnknownRowSaysSoAndStillAsks() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            XCTAssertFalse(core.dequeueMessage("s-1", messageId: "q-9"))
            let frame = await daemon.awaitFrame(ofType: "dequeueMessage")
            XCTAssertEqual(frame?["messageId"] as? String, "q-9")
        }
    }

    /// An edit keeps the row's id and its slot in delivery order: a requeue would send
    /// the head of the queue to the back of it.
    func testAnEditKeepsTheIdAndTheSlot() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            let first = try await core.queueMessageConfirmed("s-1", text: "first")
            _ = try await core.queueMessageConfirmed("s-1", text: "second")
            let edited = try await core.editQueuedConfirmed("s-1", messageId: first.id,
                                                            text: "first, revised")
            XCTAssertEqual(edited.id, first.id)
            XCTAssertEqual(core.queuedMessages("s-1").map(\.text), ["first, revised", "second"])
        }
    }

    /// An out-of-order snapshot is dropped whole rather than allowed to un-do a change
    /// that has already been seen.
    func testASnapshotOlderThanTheCachedOneIsDropped() async throws {
        let daemon = QueueDaemon()
        // An empty queue at revision 0, sent straight after the snapshot that confirms
        // the write. Applying it would leave the client believing the row it has just
        // been handed does not exist.
        daemon.afterQueueMessage = [
            json(["type": "queue", "sessionId": "s-1", "revision": 0, "items": []]),
        ]
        try await withQueueDaemon(daemon) { core in
            _ = try await core.queueMessageConfirmed("s-1", text: "kept")
            // The stale frame rides the same reply batch, so it has already been read
            // by the time the write is confirmed; a short wait covers the dispatch hop.
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(core.queuedMessages("s-1").map(\.text), ["kept"])
        }
    }

    // MARK: - The write that did not happen

    /// The assertion this ticket is really about. The core refuses, and the call throws
    /// with the core's own code in it — so a caller that clears a basket on success
    /// keeps the basket.
    func testARefusedWriteThrowsWithTheCoresOwnReason() async throws {
        let daemon = QueueDaemon()
        daemon.refuseQueueMessageWith = "queue-item-not-found"
        try await withQueueDaemon(daemon) { core in
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "into the void")
                XCTFail("a refused queue write must not answer like one that landed")
            } catch let error as QueueWriteError {
                XCTAssertEqual(error.sessionId, "s-1")
                XCTAssertTrue(error.reason.contains("queue-item-not-found"), error.reason)
                // And the error is user-facing text, because a banner shows it.
                XCTAssertEqual(error.localizedDescription, error.reason)
            }
            // The refusal changed nothing, so there is still no queue for this session.
            XCTAssertTrue(core.queuedMessages("s-1").isEmpty)
        }
    }

    /// A refusal is routed to the write waiting on it and consumed there. It must not
    /// be left to fail whatever else is in flight, and it must not go unclaimed.
    func testARefusalDoesNotOutliveTheWriteItAnswers() async throws {
        let daemon = QueueDaemon()
        daemon.refuseQueueMessageWith = "queue-unavailable"
        try await withQueueDaemon(daemon) { core in
            for attempt in 1...2 {
                do {
                    _ = try await core.queueMessageConfirmed("s-1", text: "attempt \(attempt)")
                    XCTFail("attempt \(attempt) must have been refused")
                } catch let error as QueueWriteError {
                    XCTAssertTrue(error.reason.contains("queue-unavailable"), error.reason)
                }
            }
            XCTAssertTrue(core.isConnected, "a queue refusal is not a connection failure")
        }
    }

    /// Silence is a failure too, and it is the one the old stub was: a frame goes out,
    /// nothing comes back, and the caller used to be told it worked.
    func testAWriteNothingAnswersThrowsRatherThanReportingSuccess() async throws {
        let daemon = QueueDaemon()
        daemon.swallowQueueMessage = true
        try await withQueueDaemon(daemon) { core in
            let start = Date()
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "unanswered")
                XCTFail("an unconfirmed queue write must not answer like a confirmed one")
            } catch let error as QueueWriteError {
                XCTAssertTrue(error.reason.contains("did not confirm"), error.reason)
            }
            // It waited rather than failing on the way out, and it did not wait forever.
            let waited = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(waited, 1)
            XCTAssertLessThan(waited, 20)
            XCTAssertTrue(core.queuedMessages("s-1").isEmpty)
        }
    }

    /// A whitespace-only message is not a message: the daemon drops it without a
    /// snapshot, deliberately. Refused here with a reason instead of sent to wait out a
    /// confirmation that is never coming.
    func testAWhitespaceOnlyMessageIsRefusedWithoutBeingSent() async throws {
        let daemon = QueueDaemon()
        try await withQueueDaemon(daemon) { core in
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "   \n  ")
                XCTFail("a whitespace-only message must not report as queued")
            } catch let error as QueueWriteError {
                XCTAssertTrue(error.reason.contains("nothing to send"), error.reason)
            }
            XCTAssertTrue(daemon.frames(ofType: "queueMessage").isEmpty,
                          "nothing should have been sent for a message the core would drop")
        }
    }

    /// The subscribe that has to precede a write is itself a frame that can go
    /// unanswered, and a write that never got its baseline was never sent at all.
    func testAWriteWhoseSubscriptionIsUnansweredNeverGoesOut() async throws {
        let daemon = QueueDaemon()
        daemon.swallowSubscribeQueue = true
        try await withQueueDaemon(daemon) { core in
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "no baseline")
                XCTFail("a write with no snapshot to confirm against must not report success")
            } catch let error as QueueWriteError {
                XCTAssertTrue(error.reason.contains("subscribeQueue"), error.reason)
                XCTAssertTrue(error.reason.contains("nothing was queued"), error.reason)
            }
            XCTAssertTrue(daemon.frames(ofType: "queueMessage").isEmpty)
        }
    }

    /// A daemon that goes away with a write in flight: the socket that would have
    /// carried the confirmation is gone, so the write fails at once rather than waiting
    /// out its budget for an answer that cannot arrive.
    func testAWriteInFlightWhenTheSocketDropsFailsImmediately() async throws {
        let daemon = QueueDaemon()
        daemon.closeOnQueueMessage = true
        try await withQueueDaemon(daemon) { core in
            let start = Date()
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "into a closing socket")
                XCTFail("a write whose socket dropped must not report success")
            } catch let error as QueueWriteError {
                XCTAssertTrue(error.reason.contains("connection dropped"), error.reason)
            }
            // Immediately, not after the 5s confirmation budget.
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
            XCTAssertTrue(core.queuedMessages("s-1").isEmpty)
        }
    }

    /// The capability is still the first gate, and it throws rather than answering with
    /// a row: a core that does not advertise `queue` has nowhere to put a message.
    func testACoreWithoutTheCapabilityThrowsAndSendsNothing() async throws {
        let daemon = QueueDaemon()
        daemon.capabilities = ["inputAck", "resizeAck", "screen"]
        try await withQueueDaemon(daemon) { core in
            XCTAssertFalse(core.supports(.queue))
            do {
                _ = try await core.queueMessageConfirmed("s-1", text: "nowhere to go")
                XCTFail("a core without the queue capability must not accept a message")
            } catch let error as CoreCapabilityError {
                XCTAssertEqual(error.capability, .queue)
            }
            XCTAssertTrue(daemon.queueFrameTypes.isEmpty)
            XCTAssertTrue(core.queuedMessages("s-1").isEmpty)
            XCTAssertFalse(core.dequeueMessage("s-1", messageId: "q-1"))
        }
    }

    /// `editQueued` is gated on its own capability, which the frame's own scenario is
    /// separate for: a core with a queue need not have an editable one.
    func testAnEditOnACoreWithoutQueueEditIsRefused() async throws {
        let daemon = QueueDaemon()
        daemon.capabilities = ["inputAck", "resizeAck", "screen", "queue"]
        try await withQueueDaemon(daemon) { core in
            do {
                _ = try await core.editQueuedConfirmed("s-1", messageId: "q-1", text: "revised")
                XCTFail("an edit on a core without queueEdit must not report success")
            } catch let error as CoreOperationUnsupported {
                XCTAssertTrue(error.detail.contains("queueEdit"), error.detail)
            }
            XCTAssertTrue(daemon.frames(ofType: "editQueued").isEmpty)
        }
    }
}

// MARK: - The stand-in daemon

/// Answers the four queue frames the way `juancoded` does: a baseline snapshot on
/// subscribe, a complete snapshot after every change, ids it mints itself, and a
/// `queue-`prefixed error frame for a refusal. Each behaviour a test needs to bend is a
/// switch rather than a subclass.
private final class QueueDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var items: [String: [[String: Any]]] = [:]
    private var revisions: [String: Int] = [:]
    private var nextId = 1

    /// What the handshake advertises. `queueEdit` is in the default set because the
    /// daemon advertises it.
    var capabilities: [String] = ["inputAck", "resizeAck", "screen", "sessionMeta",
                                  "queue", "queueEdit"]
    /// Answer every `queueMessage` with this error code instead of enqueuing.
    var refuseQueueMessageWith: String?
    /// Take the `queueMessage` and say nothing at all.
    var swallowQueueMessage = false
    /// Take the `subscribeQueue` and never send the baseline.
    var swallowSubscribeQueue = false
    /// Extra frames to send straight after the snapshot that confirms a `queueMessage`.
    var afterQueueMessage: [String] = []
    /// Close the socket instead of answering a `queueMessage`.
    var closeOnQueueMessage = false

    var frames: [[String: Any]] { lock.withLock { received } }
    /// Only the queue frames, in order. The client also sends handshake-time frames
    /// (`listSessions`, the reaper policy) whose presence depends on capabilities these
    /// tests are not about.
    var queueFrameTypes: [String] {
        frames.compactMap { $0["type"] as? String }
            .filter { ["subscribeQueue", "unsubscribeQueue", "queueMessage",
                       "dequeueMessage", "editQueued"].contains($0) }
    }
    func frames(ofType type: String) -> [[String: Any]] {
        frames.filter { $0["type"] as? String == type }
    }

    /// Wait for a frame of `type` to be recorded. `queueMessage` and friends that a
    /// caller awaits need no wait, but a fire-and-forget frame (`dequeueMessage`) is
    /// written to the socket after the call has already returned.
    func awaitFrame(ofType type: String) async -> [String: Any]? {
        for _ in 0..<50 {
            if let frame = frames(ofType: type).first { return frame }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    /// Everything this daemon should say in reply to `frame`, in order.
    func replies(to frame: [String: Any]) -> [String] {
        lock.withLock { received.append(frame) }
        guard let type = frame["type"] as? String,
              let session = frame["sessionId"] as? String else { return [] }
        switch type {
        case "subscribeQueue":
            return swallowSubscribeQueue ? [] : [snapshot(session, bump: false)]
        case "queueMessage":
            if swallowQueueMessage { return [] }
            if let code = refuseQueueMessageWith { return [refusal(session, code)] }
            guard let text = frame["text"] as? String else { return [] }
            lock.withLock {
                let id = "q-\(nextId)"
                nextId += 1
                items[session, default: []].append([
                    "id": id, "text": text, "kind": "text", "source": "wire",
                    "state": "pending", "createdAt": 1_700_000_000_000,
                ])
            }
            return [snapshot(session, bump: true)] + afterQueueMessage
        case "dequeueMessage":
            guard let id = frame["messageId"] as? String else { return [] }
            let removed = lock.withLock { () -> Bool in
                let before = items[session]?.count ?? 0
                items[session]?.removeAll { ($0["id"] as? String) == id }
                return (items[session]?.count ?? 0) < before
            }
            return removed ? [snapshot(session, bump: true)] : [refusal(session, "queue-item-not-found")]
        case "editQueued":
            guard let id = frame["messageId"] as? String,
                  let text = frame["text"] as? String else { return [] }
            let edited = lock.withLock { () -> Bool in
                guard let index = items[session]?.firstIndex(where: { ($0["id"] as? String) == id })
                else { return false }
                // In place: same id, same slot.
                items[session]?[index]["text"] = text
                return true
            }
            return edited ? [snapshot(session, bump: true)] : [refusal(session, "queue-item-not-found")]
        default:
            return []
        }
    }

    private func snapshot(_ session: String, bump: Bool) -> String {
        let (rows, revision) = lock.withLock { () -> ([[String: Any]], Int) in
            if bump { revisions[session] = (revisions[session] ?? 0) + 1 }
            return (items[session] ?? [], revisions[session] ?? 0)
        }
        return json(["type": "queue", "sessionId": session, "revision": revision, "items": rows])
    }

    private func refusal(_ session: String, _ code: String) -> String {
        json(["type": "error", "sessionId": session, "message": code])
    }
}

/// Every queue snapshot a subscriber was handed, in order.
private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    func record(_ list: [String]) { lock.withLock { stored.append(list) } }
    var lists: [[String]] { lock.withLock { stored } }

    /// Wait until the last snapshot is `expected`, so an assertion is not racing the
    /// bus. Fails the wait by timing out rather than hanging.
    func settle(on expected: [String]) async throws {
        for _ in 0..<50 where lists.last != expected {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }
}

private func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func makeApplication(_ daemon: QueueDaemon) -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/ws") { inbound, outbound, _ in
        try await outbound.writeTextMessage(json([
            "type": "serverInfo", "protocolVersion": 1, "clientId": "test-client",
            "capabilities": daemon.capabilities,
        ]))
        for try await message in inbound.messages(maxSize: 1 << 20) {
            guard case .text(let text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let replies = daemon.replies(to: frame)
            // Returning from the handler closes the socket, which is how a daemon going
            // away with a write in flight is staged: the frame was received, and the
            // answer to it never comes.
            if daemon.closeOnQueueMessage, frame["type"] as? String == "queueMessage" { return }
            for line in replies { try await outbound.writeTextMessage(line) }
        }
    }
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "queue-daemon"))
}

/// Connect a client to a booted stand-in daemon. `connect` blocks on the handshake, so
/// it is run off the cooperative pool.
private func withQueueDaemon(
    _ daemon: QueueDaemon,
    _ body: @escaping @Sendable (RustCoreClient) async throws -> Void
) async throws {
    let mirrorPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("juancode-queue-\(UUID().uuidString).db")
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }
    try await makeApplication(daemon).test(.live) { client in
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

// MARK: - Against a real daemon

/// The same queue path against a REAL `juancoded`, because the stand-in above only
/// proves this client agrees with itself about the frames.
///
/// This is the acceptance the ticket asks for: the queued message ARRIVING. The fake
/// agent echoes what it is sent and acts on `ECHO <text>`, so a line appearing in the
/// session's output is the daemon having claimed the row, typed it into the pty and
/// pressed Enter — the whole delivery, not a green assertion about a frame.
///
/// Opt-in, and skipped otherwise: it needs a daemon, and a daemon spawns ptys. Boot one
/// on its own port and its own data dir, never :4280 or :4281:
///
///     cargo build -p juancoded --manifest-path apps/juancoded/Cargo.toml
///     JUANCODED_PORT=4292 \
///     JUANCODED_SOCKET=/tmp/juancoded-queue.sock \
///     JUANCODED_DATA_DIR=/tmp/juancoded-queue \
///     JUANCODE_CLAUDE_BIN=$PWD/apps/wire-conformance/fixtures/fake-agent.sh \
///     ./apps/juancoded/target/debug/juancoded &
///
///     JUANCODE_RUST_QUEUE_URL=http://127.0.0.1:4292 \
///     swift test --package-path apps/native --filter RustCoreQueueLiveTests
final class RustCoreQueueLiveTests: XCTestCase {
    private var core: RustCoreClient!
    private var mirrorPath: String!

    override func setUpWithError() throws {
        guard let url = ProcessInfo.processInfo.environment["JUANCODE_RUST_QUEUE_URL"],
              !url.isEmpty else {
            throw XCTSkip("set JUANCODE_RUST_QUEUE_URL to a booted juancoded to run these")
        }
        mirrorPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-queue-live-\(UUID().uuidString).db")
        core = try RustCoreClient.connect(baseURL: url, mirrorPath: mirrorPath, timeout: 5)
    }

    override func tearDownWithError() throws {
        core?.shutdown()
        core = nil
        guard let mirrorPath else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }

    /// Queue a message into a live session and watch the agent act on it.
    func testAQueuedMessageReachesTheAgent() throws {
        XCTAssertTrue(core.supports(.queue), "this daemon does not advertise queue")
        let session = try core.create(provider: .claude, cwd: NSTemporaryDirectory(),
                                      cols: 100, rows: 30,
                                      opts: SpawnOptions(skipPermissions: true, model: nil),
                                      worktreePath: nil, dispatchId: nil,
                                      initialInput: nil, onSeedFailure: nil)
        defer { session.kill() }

        let marker = "queued-arrived-\(Int(Date().timeIntervalSince1970))"
        let arrived = expectation(description: "the agent acted on the queued message")
        // The fake agent echoes what it is typed and then acts on it, so the marker
        // comes past twice; either sighting is the delivery.
        arrived.assertForOverFulfill = false
        let cancel = session.subscribeOutput(replay: false) { bytes in
            if String(decoding: bytes, as: UTF8.self).contains(marker) { arrived.fulfill() }
        }
        defer { cancel() }

        let queued = expectation(description: "the core confirmed the queue write")
        let core = core!
        Task {
            let item = try await core.queueMessageConfirmed(session.id, text: "ECHO \(marker)")
            print("the daemon minted queue row \(item.id) for \(session.id)")
            queued.fulfill()
        }
        wait(for: [queued], timeout: 15)
        // No kick: the daemon's own delivery pump takes it from here, which is why
        // `RemoteLiveSession.kickQueue` has nothing to send.
        wait(for: [arrived], timeout: 30)
        // Delivered means gone: the queue is a queue, not a log. Polled rather than
        // read once, because the agent echoes the text before the engine has settled
        // the claim behind it, so the row is still in flight for a moment after the
        // output that proves it was typed.
        let drained = expectation(description: "the delivered row left the queue")
        let watched = core
        Task {
            for _ in 0..<60 where !watched.queuedMessages(session.id).isEmpty {
                await Nap.ms(100)
            }
            if watched.queuedMessages(session.id).isEmpty { drained.fulfill() }
        }
        wait(for: [drained], timeout: 15)
    }

    /// The failure half against the real thing: the daemon refuses a message addressed
    /// to a session it does not have, and the refusal reaches the caller.
    func testTheDaemonRefusesAMessageForASessionItDoesNotHave() throws {
        XCTAssertTrue(core.supports(.queue), "this daemon does not advertise queue")
        let refused = expectation(description: "the daemon refused the write")
        let core = core!
        Task {
            do {
                _ = try await core.queueMessageConfirmed("not-a-session-\(UUID().uuidString)",
                                                         text: "nowhere to go")
                XCTFail("the daemon must not accept a message for a session it does not have")
            } catch let error as QueueWriteError {
                print("the daemon refused it: \(error.reason)")
                XCTAssertTrue(error.reason.contains("queue-item-not-found"), error.reason)
                refused.fulfill()
            }
        }
        wait(for: [refused], timeout: 15)
    }
}
