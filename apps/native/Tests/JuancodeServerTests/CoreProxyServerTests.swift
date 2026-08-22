import XCTest
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import NIOCore
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// The relay that serves 4280 for a launch whose core is the `juancoded` daemon
/// (juancode-bse5). Two halves, tested apart: the REST answers this process gives
/// from its mirror, and the verbatim `/ws` relay to the daemon, which needs real
/// sockets on both sides.
final class CoreProxyServerTests: XCTestCase {

    // MARK: - Fixtures

    private static func meta(_ id: String, worktree: String? = nil) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: "Claude · \(id)",
                    status: .running, exitCode: nil, createdAt: nowMs(), updatedAt: nowMs(),
                    cliSessionId: "cli-\(id)", skipPermissions: false,
                    worktreePath: worktree, usage: nil)
    }

    /// A mirror the closures read and write, so a delete is observable.
    private final class FakeMirror: @unchecked Sendable {
        var rows: [SessionMeta]
        var killed: [String] = []
        init(_ rows: [SessionMeta]) { self.rows = rows }

        func source() -> CoreProxyServer.Source {
            CoreProxyServer.Source(
                sessions: { [self] in rows },
                session: { [self] id in rows.first { $0.id == id } },
                searchSessions: { [self] q, _ in
                    rows.filter { $0.title.contains(q) }.map { SearchHit(meta: $0, snippet: "") }
                },
                kill: { [self] id in killed.append(id) },
                deleteSession: { [self] id in rows.removeAll { $0.id == id } },
                backendName: "rust")
        }
    }

    private static func json(_ res: TestResponse) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView),
                                          options: [.fragmentsAllowed])
    }

    /// Drive the REST half in-process. The upstream URL is never dialled here: no
    /// route in this half talks to the daemon.
    private func withProxy(
        _ mirror: FakeMirror,
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let app = Application(router: CoreProxyServer.buildRouter(
            source: mirror.source(), upstreamBaseURL: "http://127.0.0.1:4290"))
        try await app.test(.router) { client in try await body(client) }
    }

    // MARK: - REST from the mirror

    func testHealthNamesTheCoreAndTheRelayTarget() async throws {
        let mirror = FakeMirror([])
        try await withProxy(mirror) { client in
            try await client.execute(uri: "/api/health", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                let body = Self.json(res) as? [String: Any]
                XCTAssertEqual(body?["ok"] as? Bool, true)
                XCTAssertEqual(body?["core"] as? String, "rust")
                XCTAssertEqual(body?["relayingTo"] as? String, "http://127.0.0.1:4290")
            }
        }
    }

    /// The one the sidecar's session list, the Telegram formatter and the phone
    /// console all hang off.
    func testSessionsListComesFromTheMirror() async throws {
        let mirror = FakeMirror([Self.meta("s1"), Self.meta("s2")])
        try await withProxy(mirror) { client in
            try await client.execute(uri: "/api/sessions", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                let ids = (Self.json(res) as? [[String: Any]])?.compactMap { $0["id"] as? String }
                XCTAssertEqual(ids, ["s1", "s2"])
            }
        }
    }

    func testSessionByIdAndMissingOne() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await withProxy(mirror) { client in
            try await client.execute(uri: "/api/sessions/s1", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["id"] as? String, "s1")
            }
            try await client.execute(uri: "/api/sessions/nope", method: .get) { res in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    func testDeleteKillsThePtyAndDropsTheRow() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await withProxy(mirror) { client in
            try await client.execute(uri: "/api/sessions/s1", method: .delete) { res in
                XCTAssertEqual(res.status, .noContent)
            }
            try await client.execute(uri: "/api/sessions/s1", method: .delete) { res in
                XCTAssertEqual(res.status, .notFound)
            }
        }
        XCTAssertEqual(mirror.killed, ["s1"])
        XCTAssertTrue(mirror.rows.isEmpty)
    }

    func testSearchNeedsTwoCharacters() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await withProxy(mirror) { client in
            try await client.execute(uri: "/api/search?q=s", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 0)
            }
            try await client.execute(uri: "/api/search?q=s1", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 1)
            }
        }
    }

    /// An endpoint this core cannot answer says which core is running and why,
    /// instead of a 404 that reads like a typo.
    func testUnservedEndpointsSayWhyIn501() async throws {
        let mirror = FakeMirror([])
        try await withProxy(mirror) { client in
            for (uri, method) in [("/api/pr-webhook", HTTPRequest.Method.post),
                                  ("/api/tracked-prs", .get),
                                  ("/api/sessions/s1/diff", .get),
                                  ("/presence", .get)] {
                try await client.execute(uri: uri, method: method) { res in
                    XCTAssertEqual(res.status, .notImplemented, "\(uri)")
                    let msg = (Self.json(res) as? [String: Any])?["error"] as? String ?? ""
                    XCTAssertTrue(msg.contains("rust"), "\(uri): \(msg)")
                }
            }
        }
    }

    func testUnservedMessageNamesTheEndpoint() {
        let m = CoreProxyServer.unservedMessage("/api/pr-webhook", core: "rust")
        XCTAssertTrue(m.hasPrefix("/api/pr-webhook is not served with the rust core"), m)
        XCTAssertTrue(m.contains("PR tracking"), m)
    }

    // MARK: - Upstream URL

    func testWebsocketURLConversion() throws {
        XCTAssertEqual(try CoreProxyServer.websocketURL(base: "http://127.0.0.1:4290").absoluteString,
                       "ws://127.0.0.1:4290/ws")
        XCTAssertEqual(try CoreProxyServer.websocketURL(base: "https://core.example").absoluteString,
                       "wss://core.example/ws")
        XCTAssertEqual(try CoreProxyServer.websocketURL(base: "ws://127.0.0.1:4290").absoluteString,
                       "ws://127.0.0.1:4290/ws")
        XCTAssertThrowsError(try CoreProxyServer.websocketURL(base: "ftp://nope"))
    }

    // MARK: - The /ws relay, over real sockets

    /// A stand-in daemon: greets like `serverInfo` does, then echoes every frame
    /// back with a marker so the test can prove it made the round trip rather than
    /// being answered locally.
    private func makeFakeDaemon() -> some ApplicationProtocol {
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { inbound, outbound, _ in
            try await outbound.writeTextMessage(#"{"type":"serverInfo","protocolVersion":1}"#)
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let text) = message else { continue }
                try await outbound.writeTextMessage("echo:" + text)
            }
        }
        return Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "fake-daemon"))
    }

    /// The whole point: a client that only knows 4280 reaches the daemon's frames,
    /// unrewritten, in both directions.
    func testWsFramesRelayBothWays() async throws {
        let mirror = FakeMirror([])
        try await makeFakeDaemon().test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: "http://127.0.0.1:\(daemonPort)",
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { proxyClient in
                let proxyPort = try XCTUnwrap(proxyClient.port)
                let session = URLSession(configuration: .ephemeral)
                let task = session.webSocketTask(
                    with: URL(string: "ws://127.0.0.1:\(proxyPort)/ws")!)
                task.resume()
                defer { task.cancel(with: .goingAway, reason: nil) }

                guard case .string(let greeting) = try await task.receive() else {
                    return XCTFail("expected a text greeting through the relay")
                }
                XCTAssertTrue(greeting.contains("serverInfo"), greeting)

                try await task.send(.string(#"{"type":"input","sessionId":"s1","data":"hi"}"#))
                guard case .string(let echoed) = try await task.receive() else {
                    return XCTFail("expected the daemon's echo through the relay")
                }
                XCTAssertEqual(echoed, #"echo:{"type":"input","sessionId":"s1","data":"hi"}"#)
            }
        }
    }

    /// A real core does not answer one frame and stop: it pushes `attached`, then a
    /// burst of `output`, then `activity`. The relay has to keep up with all of it,
    /// not just the first reply.
    func testRelayKeepsPumpingAfterTheFirstFrames() async throws {
        let mirror = FakeMirror([])
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { inbound, outbound, _ in
            try await outbound.writeTextMessage(#"{"type":"serverInfo","protocolVersion":1}"#)
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text = message else { continue }
                for i in 0..<50 {
                    try await outbound.writeTextMessage(#"{"type":"output","n":\#(i)}"#)
                }
            }
        }
        let daemon = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "chatty-daemon"))

        try await daemon.test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: "http://127.0.0.1:\(daemonPort)",
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { proxyClient in
                let proxyPort = try XCTUnwrap(proxyClient.port)
                let task = URLSession(configuration: .ephemeral)
                    .webSocketTask(with: URL(string: "ws://127.0.0.1:\(proxyPort)/ws")!)
                task.resume()
                defer { task.cancel(with: .goingAway, reason: nil) }
                _ = try await task.receive() // the handshake
                try await task.send(.string(#"{"type":"attach","sessionId":"s1"}"#))
                var seen: [Int] = []
                for _ in 0..<50 {
                    guard case .string(let text) = try await task.receive(),
                          let data = text.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let n = obj["n"] as? Int else { continue }
                    seen.append(n)
                }
                XCTAssertEqual(seen, Array(0..<50))
            }
        }
    }

    /// A daemon that is not there must close the relayed socket, not hold it open:
    /// the sidecar's reconnect loop is what recovers, and it only runs on a close.
    func testRelayClosesWhenTheDaemonIsUnreachable() async throws {
        let mirror = FakeMirror([])
        // Port 1 on loopback: privileged and unbound, so the connect fails fast.
        let proxy = try CoreProxyServer.makeApplication(
            source: mirror.source(), upstreamBaseURL: "http://127.0.0.1:1",
            host: "127.0.0.1", port: 0)
        try await proxy.test(.live) { proxyClient in
            let proxyPort = try XCTUnwrap(proxyClient.port)
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(proxyPort)/ws")!)
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }
            do {
                _ = try await task.receive()
                XCTFail("the relay should have closed instead of answering")
            } catch {
                // Any receive failure is the pass: the socket did not stay open.
            }
        }
    }
}
