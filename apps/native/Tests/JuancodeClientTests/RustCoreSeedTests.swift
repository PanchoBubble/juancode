import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import JuancodeCore
import XCTest

@testable import JuancodeClient

/// Where an opening prompt goes on a remote core, over a real socket against a
/// stand-in daemon.
///
/// The bug these cover is not a wrong value, it is an absent field: `create` used to
/// leave `initialInput` off the frame, and the app pasted the prompt itself through
/// `RemoteLiveSession.autoSubmit` — a blind paste plus a CR 120ms after the CLI's
/// first byte of output, which is seconds before its input box exists. A dispatched
/// agent was left with its prompt typed and unsent, so nothing ran. The frame is
/// therefore the assertion: the daemon owns the pty and the parsed screen, so it is
/// the only side that can confirm a paste landed before pressing Enter.
final class RustCoreSeedTests: XCTestCase {

    // MARK: - The prompt travels on the create

    func testCreateCarriesTheOpeningPromptSoTheCoreDeliversIt() async throws {
        let daemon = StandInDaemon()
        try await withStandInDaemon(daemon) { core in
            _ = try await Task.detached {
                try core.create(provider: .claude, cwd: "/tmp", cols: 80, rows: 24,
                                opts: SpawnOptions(skipPermissions: true, model: nil),
                                worktreePath: nil, dispatchId: "dispatch-1",
                                initialInput: "fix the failing test", onSeedFailure: nil)
            }.value
            let creates = daemon.frames(ofType: "create")
            XCTAssertEqual(creates.count, 1)
            XCTAssertEqual(creates.first?["initialInput"] as? String, "fix the failing test")
            XCTAssertEqual(creates.first?["dispatchId"] as? String, "dispatch-1")
            // Nothing was typed from here: an app-side paste is the failure being
            // fixed, not a belt-and-braces second delivery.
            XCTAssertTrue(daemon.frames(ofType: "input").isEmpty,
                          "the client must not write the prompt itself")
        }
    }

    /// An empty prompt is no prompt: the field is absent rather than an empty string
    /// the core would have to special-case.
    func testCreateWithoutAPromptSendsNoSeedField() async throws {
        let daemon = StandInDaemon()
        try await withStandInDaemon(daemon) { core in
            _ = try await Task.detached {
                try core.create(provider: .claude, cwd: "/tmp", cols: 80, rows: 24,
                                opts: SpawnOptions(skipPermissions: true, model: nil),
                                worktreePath: nil, dispatchId: nil,
                                initialInput: "", onSeedFailure: nil)
            }.value
            XCTAssertNil(daemon.frames(ofType: "create").first?["initialInput"])
        }
    }

    // MARK: - A delivery the core could not finish

    /// The daemon reports an undeliverable seed as an error frame for that session,
    /// long after the create was acked. It has to reach the caller that asked for the
    /// prompt: a session that looks started and is silently idle is exactly the state
    /// this path exists to make impossible.
    func testAnUndeliveredPromptIsReportedToTheCallerThatAskedForIt() async throws {
        let daemon = StandInDaemon()
        daemon.afterCreate = { id in
            [json(["type": "error", "sessionId": id,
                   "message": "the initial prompt was not delivered: the prompt stayed in the input box"])]
        }
        let reported = ReasonBox()
        try await withStandInDaemon(daemon) { core in
            let session = try await Task.detached {
                try core.create(provider: .claude, cwd: "/tmp", cols: 80, rows: 24,
                                opts: SpawnOptions(skipPermissions: true, model: nil),
                                worktreePath: nil, dispatchId: nil,
                                initialInput: "fix the failing test",
                                onSeedFailure: { sessionId, why in
                                    reported.set(sessionId: sessionId, reason: why)
                                })
            }.value
            // The create is still answered normally: the seed's verdict comes later
            // and on its own, so it is not mistaken for the lifecycle reply.
            XCTAssertEqual(session.id, "session-1")
            XCTAssertTrue(session.isRunning)
            for _ in 0..<50 where reported.sessionId == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(reported.sessionId, "session-1")
            XCTAssertTrue(reported.reason?.contains("stayed in the input box") == true,
                          reported.reason ?? "nothing was reported")
        }
    }
}

// MARK: - The stand-in daemon

/// Greets like a real core, answers a `create` with `created` + `attached`, records
/// every frame it was sent, and then sends whatever `afterCreate` asks for.
private final class StandInDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    /// Sent after the `created`/`attached` pair, when a test sets it: the shape of a
    /// delivery the daemon accepted and could not finish.
    var afterCreate: (@Sendable (_ sessionId: String) -> [String])?

    func record(_ frame: [String: Any]) { lock.withLock { received.append(frame) } }
    var frames: [[String: Any]] { lock.withLock { received } }
    func frames(ofType type: String) -> [[String: Any]] {
        frames.filter { $0["type"] as? String == type }
    }
}

/// A `@Sendable` sink for the reporter's two strings.
private final class ReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (String, String)?
    func set(sessionId: String, reason: String) { lock.withLock { stored = (sessionId, reason) } }
    var sessionId: String? { lock.withLock { stored?.0 } }
    var reason: String? { lock.withLock { stored?.1 } }
}

private func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func metaObject(_ meta: SessionMeta) -> [String: Any] {
    let data = try! JSONEncoder().encode(meta)
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private func makeApplication(_ daemon: StandInDaemon) -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.ws("/ws") { inbound, outbound, _ in
        try await outbound.writeTextMessage(json([
            "type": "serverInfo", "protocolVersion": 1, "clientId": "test-client",
            "capabilities": ["inputAck", "resizeAck", "screen", "sessionMeta"],
        ]))
        for try await message in inbound.messages(maxSize: 1 << 20) {
            guard case .text(let text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            daemon.record(frame)
            guard frame["type"] as? String == "create" else { continue }
            let session = SessionMeta(id: "session-1", provider: .claude,
                                      cwd: frame["cwd"] as? String ?? "/tmp", title: "seeded",
                                      status: .running, exitCode: nil, createdAt: nowMs(),
                                      updatedAt: nowMs(), cliSessionId: nil, skipPermissions: true,
                                      worktreePath: nil, usage: nil)
            let object = metaObject(session)
            try await outbound.writeTextMessage(json(["type": "created", "session": object]))
            try await outbound.writeTextMessage(json([
                "type": "attached", "sessionId": session.id, "scrollback": "", "session": object,
            ]))
            for line in daemon.afterCreate?(session.id) ?? [] {
                try await outbound.writeTextMessage(line)
            }
        }
    }
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "stand-in-daemon"))
}

/// Connect a client to a booted stand-in daemon. `connect` and `create` both block on
/// frames, so they are run off the cooperative pool.
private func withStandInDaemon(
    _ daemon: StandInDaemon,
    _ body: @escaping @Sendable (RustCoreClient) async throws -> Void
) async throws {
    let mirrorPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("juancode-seed-\(UUID().uuidString).db")
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }
    try await makeApplication(daemon).test(.live) { client in
        let port = try XCTUnwrap(client.port)
        let core = try await Task.detached {
            try RustCoreClient.connect(baseURL: "http://127.0.0.1:\(port)",
                                       mirrorPath: mirrorPath, timeout: 5)
        }.value
        defer { core.shutdown() }
        try await body(core)
    }
}
