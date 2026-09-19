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

        /// Repo + number of every trigger the relay handed on, and whether the core
        /// behind it would take one at all.
        var forwarded: [(String, Int)] = []
        var canForward = false

        func forwardingSource() -> CoreProxyServer.Source {
            var source = self.source()
            source = CoreProxyServer.Source(
                sessions: source.sessions, session: source.session,
                searchSessions: source.searchSessions, kill: source.kill,
                deleteSession: source.deleteSession, backendName: source.backendName,
                globalPause: source.globalPause,
                forwardPrWebhook: { [self] repo, number in
                    forwarded.append((repo, number))
                    return canForward
                })
            return source
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
        try await withProxy(source: mirror.source(), body)
    }

    private func withProxy(
        source: CoreProxyServer.Source,
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let app = Application(router: CoreProxyServer.buildRouter(
            source: source, upstreamBaseURL: "http://127.0.0.1:4290"))
        try await app.test(.router) { client in try await body(client) }
    }

    // MARK: - Live test servers

    /// Every server booted with `.test(.live)` binds the NAME `localhost`:
    /// HummingbirdTesting replaces whatever address the application's own
    /// configuration gives, and its own client dials that same name. On a machine
    /// whose resolver answers `::1` first, the v4 literal is therefore left
    /// unbound and a hand-rolled URL aimed at `127.0.0.1` is refused by a server
    /// that is up. Build every URL aimed at a live test server from the name it
    /// bound, not from a literal.
    private static func liveURL(_ scheme: String, _ port: Int, _ path: String = "") -> String {
        "\(scheme)://localhost:\(port)\(path)"
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
            // Endpoints leave this list as the daemon grows them: `/diff` went with
            // juancode-52e8.14.5 and `/review` with juancode-52e8.14.6, both now
            // forwarded rather than refused. So the one asserted here has to be a path
            // with NO route on the relay at all — a proxied leaf whose session the
            // mirror does not hold answers 404, which is a different sentence.
            for (uri, method) in [("/api/pr-webhook", HTTPRequest.Method.post),
                                  ("/api/tracked-prs", .get),
                                  ("/api/sessions/s1/beads", .get),
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
        XCTAssertTrue(m.contains("webhook trigger"), m)
        let tracked = CoreProxyServer.unservedMessage("/api/tracked-prs", core: "rust")
        XCTAssertTrue(tracked.contains("PR tracking"), tracked)
    }

    // MARK: - The webhook fast path (juancode-rnx6)

    /// The sidecar's trigger reaches the core through the relay, and the reply says so.
    /// The whole point: without this the poll is the core's only update path and a
    /// review comment waits up to a minute.
    func testAWebhookTriggerIsForwardedToTheCore() async throws {
        let mirror = FakeMirror([])
        mirror.canForward = true
        try await withProxy(source: mirror.forwardingSource()) { client in
            try await client.execute(
                uri: "/api/pr-webhook", method: .post,
                body: ByteBuffer(string: #"{"repo":"owner/name","number":42}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["ok"] as? Bool, true)
            }
        }
        XCTAssertEqual(mirror.forwarded.count, 1)
        XCTAssertEqual(mirror.forwarded.first?.0, "owner/name")
        XCTAssertEqual(mirror.forwarded.first?.1, 42)
    }

    /// A core that cannot take the trigger keeps the 501. A 200 here would read as a
    /// working webhook chain while every tracked PR quietly waited for its next poll,
    /// which is the failure this whole path exists to end.
    func testACoreThatCannotTakeTheTriggerStillAnswers501() async throws {
        let mirror = FakeMirror([])
        mirror.canForward = false
        try await withProxy(source: mirror.forwardingSource()) { client in
            try await client.execute(
                uri: "/api/pr-webhook", method: .post,
                body: ByteBuffer(string: #"{"repo":"owner/name","number":42}"#)) { res in
                XCTAssertEqual(res.status, .notImplemented)
            }
        }
    }

    /// A trigger that names no PR is refused before it costs the core anything: a
    /// number of 0 would match every watch's "not this one" and an empty repo would
    /// match by url fallback alone.
    func testAWebhookTriggerNeedsARepoAndAPositiveNumber() async throws {
        let mirror = FakeMirror([])
        mirror.canForward = true
        try await withProxy(source: mirror.forwardingSource()) { client in
            for body in [#"{"repo":"  ","number":42}"#, #"{"repo":"owner/name","number":0}"#] {
                try await client.execute(uri: "/api/pr-webhook", method: .post,
                                         body: ByteBuffer(string: body)) { res in
                    XCTAssertEqual(res.status, .badRequest, body)
                }
            }
        }
        XCTAssertTrue(mirror.forwarded.isEmpty)
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
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { proxyClient in
                let proxyPort = try XCTUnwrap(proxyClient.port)
                let session = URLSession(configuration: .ephemeral)
                let task = session.webSocketTask(
                    with: URL(string: Self.liveURL("ws", proxyPort, "/ws"))!)
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
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { proxyClient in
                let proxyPort = try XCTUnwrap(proxyClient.port)
                let task = URLSession(configuration: .ephemeral)
                    .webSocketTask(with: URL(string: Self.liveURL("ws", proxyPort, "/ws"))!)
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

    // MARK: - The per-session reads, proxied to the daemon

    /// A stand-in daemon's HTTP half: it answers the reads the way juancoded
    /// does, and says which path it was asked for so the relay cannot be caught
    /// answering locally.
    private func makeReadingDaemon(status: HTTPResponse.Status = .ok) -> some ApplicationProtocol {
        let router = Router()
        for leaf in CoreProxyServer.sessionReadLeaves {
            router.get("/api/sessions/:id/\(leaf)") { req, ctx -> Response in
                let id = ctx.parameters.get("id") ?? ""
                let body = #"{"sessionId":"\#(id)","leaf":"\#(leaf)","cols":132,"rows":43,"query":"\#(req.uri.query ?? "")"}"#
                var headers = HTTPFields()
                headers[.contentType] = "application/json; charset=utf-8"
                return Response(status: status, headers: headers,
                                body: .init(byteBuffer: ByteBuffer(string: body)))
            }
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "reading-daemon"))
    }

    /// The bug this closes: every one of them answered 501 on the rust core, so everything
    /// that reads a session remotely saw an empty session rather than an outage
    /// (juancode-ag1e). They have to reach the daemon, and the grid the bytes were
    /// parsed at has to survive the hop — a byte ring replayed at the wrong width is
    /// garbled in every line that reached the right margin.
    func testTheSessionReadsReachTheDaemonWithTheirGridIntact() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await makeReadingDaemon().test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { client in
                for leaf in CoreProxyServer.sessionReadLeaves {
                    try await client.execute(uri: "/api/sessions/s1/\(leaf)", method: .get) { res in
                        XCTAssertEqual(res.status, .ok, leaf)
                        let body = Self.json(res) as? [String: Any]
                        XCTAssertEqual(body?["leaf"] as? String, leaf)
                        XCTAssertEqual(body?["sessionId"] as? String, "s1")
                        XCTAssertEqual(body?["cols"] as? Int, 132, leaf)
                        XCTAssertEqual(body?["rows"] as? Int, 43, leaf)
                    }
                }
            }
        }
    }

    /// The query string is the caller's bound on how much history it wants, so it has
    /// to arrive: a relay that dropped it would answer every read with the default.
    func testAReadCarriesItsQueryStringThrough() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await makeReadingDaemon().test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { client in
                try await client.execute(uri: "/api/sessions/s1/messages?limit=7", method: .get) { res in
                    XCTAssertEqual((Self.json(res) as? [String: Any])?["query"] as? String, "limit=7")
                }
            }
        }
    }

    /// The id reaches the daemon exactly as it arrived, still encoded. Re-encoding it
    /// here would turn a `%2F` into a `%252F` and the daemon would look up a session
    /// id nobody has; decoding it would send two path segments where there was one.
    func testASessionIdReachesTheDaemonStillEncoded() async throws {
        let mirror = FakeMirror([Self.meta("s/1")])
        try await makeReadingDaemon().test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { client in
                try await client.execute(uri: "/api/sessions/s%2F1/scrollback", method: .get) { res in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertEqual((Self.json(res) as? [String: Any])?["sessionId"] as? String, "s%2F1")
                }
            }
        }
    }

    /// The daemon's status is the answer, not this hop's opinion of it: a session the
    /// core has never heard of is a 404, and reinterpreting that as a 501 would tell a
    /// caller the core cannot serve reads at all.
    func testTheDaemonsStatusIsWhatTheCallerGets() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        try await makeReadingDaemon(status: .notFound).test(.live) { daemonClient in
            let daemonPort = try XCTUnwrap(daemonClient.port)
            let proxy = try CoreProxyServer.makeApplication(
                source: mirror.source(),
                upstreamBaseURL: Self.liveURL("http", daemonPort),
                host: "127.0.0.1", port: 0)
            try await proxy.test(.live) { client in
                try await client.execute(uri: "/api/sessions/s1/transcript", method: .get) { res in
                    XCTAssertEqual(res.status, .notFound)
                }
            }
        }
    }

    /// A core that is not answering is a bad gateway, not a 501: the route exists and
    /// the capability exists, the hop behind it failed.
    func testAnUnreachableDaemonIsA502NotA501() async throws {
        let mirror = FakeMirror([Self.meta("s1")])
        let proxy = try CoreProxyServer.makeApplication(
            source: mirror.source(), upstreamBaseURL: "http://127.0.0.1:1",
            host: "127.0.0.1", port: 0)
        try await proxy.test(.live) { client in
            try await client.execute(uri: "/api/sessions/s1/scrollback", method: .get) { res in
                XCTAssertEqual(res.status, .badGateway)
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
            let task = session.webSocketTask(with: URL(string: Self.liveURL("ws", proxyPort, "/ws"))!)
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }
            do {
                _ = try await task.receive()
                XCTFail("the relay should have closed instead of answering")
            } catch {
                // The socket did not stay open — but only a failure AFTER the relay
                // answered the upgrade proves that. A refused connection means the
                // relay was never reached and this test measured nothing.
                XCTAssertNotEqual((error as NSError).code, NSURLErrorCannotConnectToHost,
                                  "the relay itself was unreachable: \(error)")
            }
        }
    }
}
