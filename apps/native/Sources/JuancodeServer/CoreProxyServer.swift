import Foundation
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import NIOCore
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// The address the oracle sidecar (and every other remote client) knows, served
/// for a launch whose core is NOT the in-process Swift one.
///
/// `JuancodeServer` needs an `AppState` — the in-process registry, store, queue
/// and PR engine — so a rust launch had nothing to boot it with and port 4280
/// went unserved: no Telegram notifications, no remote steering, no dispatch.
/// This is the answer to that, and it is deliberately two different things at
/// once, because the truth is split:
///
///   - `/ws` is **relayed, verbatim, to the daemon**. The daemon owns the ptys, so
///     it is the only thing that can answer `input`, `create` or `subscribeScreen`,
///     and it broadcasts the `activity` the sidecar's notifications are built on.
///     Nothing is rewritten in flight: the daemon's own `serverInfo` reaches the
///     client, so a sidecar feature-detects the real core's capabilities rather
///     than a list this process invented.
///   - The REST endpoints are answered **here**, from the desktop's mirror of the
///     rows the daemon has told it about. Protocol v1 has no frame that lists a
///     core's sessions (juancode-3l2p), which is exactly why the mirror exists;
///     until there is one, this process is the only place `/api/sessions` can come
///     from.
///
/// Everything else the Swift core serves is answered with a 501 naming what is
/// missing, so a caller gets a reason instead of a 404 that reads like a bug.
public enum CoreProxyServer {
    /// The session-shaped reads and writes the proxy answers, supplied by whoever
    /// owns the core. A closure bag rather than the `CoreClient` protocol on
    /// purpose: that protocol lives in `JuancodeClient`, which depends on this
    /// target, and the dependency cannot run both ways.
    public struct Source: Sendable {
        public let sessions: @Sendable () -> [SessionMeta]
        public let session: @Sendable (String) -> SessionMeta?
        public let searchSessions: @Sendable (String, Int) -> [SearchHit]
        /// Kill the pty, if one is live. Called before the row is dropped.
        public let kill: @Sendable (String) -> Void
        /// Drop the row from the mirror.
        public let deleteSession: @Sendable (String) -> Void
        /// Name of the core behind the relay, for the 501 bodies ("rust").
        public let backendName: String
        /// This launch's paused set (juancode-tnxx), when something can act on it.
        ///
        /// The one thing on this relay that is neither answered by the daemon nor
        /// read off the mirror: a global pause is a decision about WHICH rows count
        /// as agent sessions and what a play brings back, and the daemon has no frame
        /// for it and no row that separates "the pause slept this" from the four
        /// other producers of `dormant`. So the two frames are answered here, by the
        /// same book and the same driver the desktop's own button uses.
        ///
        /// Nil, or a book with no driver installed, means nothing can serve a pause
        /// on this launch — the frames are relayed like any other unimplemented type
        /// and `globalPause` is never advertised.
        public let globalPause: GlobalPauseBook?

        public init(sessions: @escaping @Sendable () -> [SessionMeta],
                    session: @escaping @Sendable (String) -> SessionMeta?,
                    searchSessions: @escaping @Sendable (String, Int) -> [SearchHit],
                    kill: @escaping @Sendable (String) -> Void,
                    deleteSession: @escaping @Sendable (String) -> Void,
                    backendName: String,
                    globalPause: GlobalPauseBook? = nil) {
            self.sessions = sessions
            self.session = session
            self.searchSessions = searchSessions
            self.kill = kill
            self.deleteSession = deleteSession
            self.backendName = backendName
            self.globalPause = globalPause
        }
    }

    /// Largest relayed frame. Same ceiling `JuancodeServer` reads with, so a frame
    /// that fits one path fits the other.
    static let maxFrameSize = 1 << 20

    /// Serve until shutdown. `handleSignals: false` for the GUI, which owns its own
    /// lifecycle, matching `JuancodeServer.run`.
    public static func run(
        source: Source,
        upstreamBaseURL: String,
        host: String = Config.bindHost,
        port: Int = Config.port,
        handleSignals: Bool = false
    ) async throws {
        let app = try makeApplication(source: source, upstreamBaseURL: upstreamBaseURL,
                                      host: host, port: port)
        if handleSignals {
            try await app.runService()
        } else {
            try await app.runService(gracefulShutdownSignals: [])
        }
    }

    /// The whole application, built but not started, so a test can drive the same
    /// object `run` does instead of a rebuilt approximation of it.
    static func makeApplication(source: Source, upstreamBaseURL: String,
                                host: String, port: Int) throws -> some ApplicationProtocol {
        let upstream = try websocketURL(base: upstreamBaseURL)
        return Application(
            router: buildRouter(source: source, upstreamBaseURL: upstreamBaseURL),
            server: .http1WebSocketUpgrade(
                webSocketRouter: buildWSRouter(upstream: upstream, globalPause: source.globalPause)),
            configuration: .init(address: .hostname(host, port: port), serverName: "juancode")
        )
    }

    /// `http://127.0.0.1:4290` → `ws://127.0.0.1:4290/ws`. Mirrors the same
    /// conversion `WireConnection` does for the app's own client.
    static func websocketURL(base: String) throws -> URL {
        guard var comps = URLComponents(string: base) else {
            throw ProxyConfigError(base: base)
        }
        switch comps.scheme {
        case "http", nil: comps.scheme = "ws"
        case "https": comps.scheme = "wss"
        case "ws", "wss": break
        default: throw ProxyConfigError(base: base)
        }
        comps.path = "/ws"
        guard let url = comps.url else { throw ProxyConfigError(base: base) }
        return url
    }

    struct ProxyConfigError: LocalizedError {
        let base: String
        var errorDescription: String? { "Not a usable core URL to relay to: \(base)" }
    }

    // MARK: - WebSocket relay (/ws)

    /// One frame on its way to the client, so the upstream pump and the paused-set
    /// broadcast cannot write to the same socket at once.
    enum Downlink: Sendable {
        case text(String)
        case binary([UInt8])
    }

    static func buildWSRouter(upstream: URL,
                              globalPause: GlobalPauseBook?) -> Router<BasicWebSocketRequestContext> {
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { inbound, outbound, _ in
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: upstream)
            task.resume()
            defer {
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            // Two producers reach this socket now — the daemon's frames and this
            // process's own `pauseState` — so they are funnelled through one stream
            // that a single writer task drains, exactly as `JuancodeServer` does.
            let (stream, cont) = AsyncStream<Downlink>.makeStream()
            let writer = Task {
                for await frame in stream {
                    switch frame {
                    case .text(let text): try? await outbound.writeTextMessage(text)
                    case .binary(let bytes): try? await outbound.writeBinaryMessage(ByteBuffer(bytes: bytes))
                    }
                }
            }
            // Broadcast the set for as long as this connection lives, so a pause taken
            // on the desktop reaches a phone that is only watching.
            let unwatch = servedPause(globalPause)?.onChange { ids in
                cont.yield(.text(pauseStateFrame(ids)))
            }
            defer {
                unwatch?()
                cont.finish()
                writer.cancel()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pumpUpstream(task, to: cont, globalPause: globalPause) }
                group.addTask { await pumpDownstream(inbound, to: task, globalPause: globalPause) }
                // Whichever direction dies first takes the connection with it: a
                // half-open relay would leave the sidecar holding a socket that
                // looks alive and never reconnects.
                await group.next()
                task.cancel(with: .goingAway, reason: nil)
                try? await outbound.close(.normalClosure, reason: nil)
                group.cancelAll()
            }
        }
        return wsRouter
    }

    /// The book only when something can actually act on it. A book whose driver was
    /// never installed must not make the relay advertise `globalPause`: an advertised
    /// capability nothing serves is worse than an absent one, because a client stops
    /// guarding the affordance on the strength of that string.
    static func servedPause(_ book: GlobalPauseBook?) -> GlobalPauseBook? {
        guard let book, book.driver != nil else { return nil }
        return book
    }

    static func pauseStateFrame(_ ids: Set<String>) -> String {
        ServerMessage.pauseState(paused: Array(ids)).jsonString()
    }

    /// Daemon → client. Ends on the first receive failure, which is also how an
    /// unreachable daemon surfaces: `resume()` never confirms the handshake.
    private static func pumpUpstream(_ task: URLSessionWebSocketTask,
                                     to cont: AsyncStream<Downlink>.Continuation,
                                     globalPause: GlobalPauseBook?) async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .string(let text):
                    // The daemon's own `serverInfo` still reaches the client, with one
                    // capability added: this endpoint answers `pauseAll`/`resumeAll`
                    // itself, and the list has to describe what the endpoint speaks or
                    // feature detection is wrong about the surface it is talking to.
                    if let book = servedPause(globalPause),
                       let rewritten = withGlobalPauseAdvertised(text) {
                        cont.yield(.text(rewritten))
                        cont.yield(.text(pauseStateFrame(book.paused)))
                    } else {
                        cont.yield(.text(text))
                    }
                case .data(let data):
                    cont.yield(.binary(Array(data)))
                @unknown default:
                    continue
                }
            } catch {
                // A relay that goes quiet is indistinguishable from a quiet core, so
                // the reason it stopped is worth a line.
                NSLog("juancode: core relay stopped reading the daemon: \(error)")
                return
            }
        }
    }

    /// `serverInfo` with `globalPause` appended, or nil when the frame is anything
    /// else. Rebuilt from the parsed object rather than string-spliced so a daemon
    /// that grows a field does not lose it here.
    static func withGlobalPauseAdvertised(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "serverInfo" else { return nil }
        var caps = obj["capabilities"] as? [String] ?? []
        guard !caps.contains(globalPauseCapability) else { return nil }
        caps.append(globalPauseCapability)
        obj["capabilities"] = caps
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    static let globalPauseCapability = "globalPause"

    /// Client → daemon, minus the two frames this process answers itself.
    private static func pumpDownstream(_ inbound: WebSocketInboundStream,
                                       to task: URLSessionWebSocketTask,
                                       globalPause: GlobalPauseBook?) async {
        do {
            for try await message in inbound.messages(maxSize: maxFrameSize) {
                switch message {
                case .text(let text):
                    if let driver = servedPause(globalPause)?.driver,
                       let type = frameType(text), type == "pauseAll" || type == "resumeAll" {
                        // Detached: a pause sleeps every live agent and a play spawns
                        // real `--resume` processes, and neither may hold the socket's
                        // read loop while it does.
                        Task.detached {
                            if type == "pauseAll" { _ = await driver.pauseAll() }
                            else { await driver.resumeAll() }
                        }
                        continue
                    }
                    try await task.send(.string(text))
                case .binary(let buffer):
                    try await task.send(.data(Data(buffer: buffer)))
                }
            }
        } catch {
            NSLog("juancode: core relay stopped forwarding to the daemon: \(error)")
            return
        }
    }

    /// The `type` discriminator of a wire frame, or nil when it is not one.
    static func frameType(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["type"] as? String
    }

    // MARK: - REST (the subset a core with no AppState can honestly answer)

    static func buildRouter(source: Source, upstreamBaseURL: String) -> Router<BasicRequestContext> {
        let router = Router()

        router.get("/api/health") { _, _ in
            jsonResponse(ProxyHealth(ok: true, core: source.backendName, relayingTo: upstreamBaseURL))
        }

        // The desktop presence gate is tracked by `AppState`, which a launch on this
        // core does not have. Said out loud rather than answered with a made-up
        // "nobody is at the desk", which would change how a caller notifies.
        router.get("/presence") { _, _ -> Response in
            throw APIError(.notImplemented, unservedMessage("/presence", core: source.backendName))
        }

        router.get("/api/sessions") { _, _ in source.sessions() }

        router.get("/api/search") { req, _ in
            let q = (req.uri.queryParameters["q"].map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            return q.count < 2 ? [SearchHit]() : source.searchSessions(q, 50)
        }

        router.get("/api/sessions/:id") { _, ctx in
            guard let id = ctx.parameters.get("id"), let meta = source.session(id) else {
                throw APIError(.notFound, "not found")
            }
            return meta
        }

        // Kill the pty, drop the row, remove an auto-created worktree best-effort.
        // Same reach as the desktop's own delete on this core, and no further:
        // protocol v1 has no frame that tells a core to forget a session, so the
        // daemon keeps its own row either way.
        router.delete("/api/sessions/:id") { _, ctx in
            guard let id = ctx.parameters.get("id"), let meta = source.session(id) else {
                throw APIError(.notFound, "not found")
            }
            source.kill(id)
            source.deleteSession(id)
            if let wt = meta.worktreePath {
                try? await removeWorktree(wt)
            }
            return Response(status: .noContent)
        }

        // Everything else the Swift core serves. A 404 here would read as "wrong
        // URL"; this says which core is running and what it does not have.
        for method: HTTPRequest.Method in [.get, .post, .put, .delete, .patch] {
            router.on("/api/**", method: method) { req, _ -> Response in
                throw APIError(.notImplemented, unservedMessage(req.uri.path, core: source.backendName))
            }
        }

        return router
    }

    /// One sentence per unserved endpoint: what is missing and why, in the terms
    /// the rest of the app uses for a capability a core does not have.
    static func unservedMessage(_ path: String, core: String) -> String {
        let reason: String
        switch path {
        case "/api/pr-webhook", "/api/tracked-prs":
            reason = "PR tracking runs in the desktop's own core, which this launch is not using"
        case "/presence":
            reason = "desktop presence is tracked by the in-process core, which this launch is not using"
        default:
            reason = "it needs the in-process core's registry, which this launch is not using"
        }
        return "\(path) is not served with the \(core) core: \(reason)."
    }
}

/// `/api/health` on the relay says which core answers and where its ptys live, so
/// a bug report is never ambiguous about which process was in play.
struct ProxyHealth: Encodable {
    let ok: Bool
    let core: String
    let relayingTo: String
}
