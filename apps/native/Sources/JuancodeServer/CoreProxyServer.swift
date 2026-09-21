import Foundation
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import NIOCore
import JuancodeCore

/// The address the oracle sidecar (and every other remote client) knows, served
/// for a launch whose core is another process — which, since juancode-nqpm, is
/// every launch.
///
/// The server this replaced needed an in-process registry, store, queue and PR
/// engine to boot, so a launch against the daemon had nothing to serve 4280 with and
/// the port went unanswered: no Telegram notifications, no remote steering, no
/// dispatch. This is the answer to that, and it is deliberately two different things
/// at once, because the truth is split:
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
/// Everything the old in-process server served and this does not is answered with a
/// 501 naming what is missing, so a caller gets a reason instead of a 404 that reads
/// like a bug.
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

        /// Hand a GitHub webhook trigger (`owner/name`, PR number) to the core, and say
        /// whether it got there. The sidecar has already checked GitHub's HMAC; this
        /// only translates its `POST /api/pr-webhook` into the frame the daemon's watch
        /// list listens on, because that core serves no HTTP of its own.
        ///
        /// `false` — or nil, for a core with no frame for it at all — keeps the 501 this
        /// route used to always answer. A 200 that dropped the trigger would read as a
        /// working webhook chain while every tracked PR quietly waited for its next poll
        /// (juancode-rnx6).
        public let forwardPrWebhook: (@Sendable (String, Int) -> Bool)?

        /// Run one of the four working-tree writes through the core and hand back what
        /// it answered, already encoded (juancode-52e8.14.5).
        ///
        /// A closure rather than another proxied HTTP route, because the writes are NOT
        /// HTTP on the daemon: they are wire frames, so that a discard is ordered
        /// against the session's other traffic and a refusal can carry git's own
        /// sentence. This hop turns the phone's POST into that frame and waits for the
        /// correlated answer.
        ///
        /// Nil for a core with no frame for them, and the route is then not registered
        /// at all — which leaves the 501 below, naming the missing capability, instead
        /// of a 200 for a commit that never happened.
        public let gitWrite: (@Sendable (GitWrite) async -> GitWriteOutcome)?

        public init(sessions: @escaping @Sendable () -> [SessionMeta],
                    session: @escaping @Sendable (String) -> SessionMeta?,
                    searchSessions: @escaping @Sendable (String, Int) -> [SearchHit],
                    kill: @escaping @Sendable (String) -> Void,
                    deleteSession: @escaping @Sendable (String) -> Void,
                    backendName: String,
                    globalPause: GlobalPauseBook? = nil,
                    forwardPrWebhook: (@Sendable (String, Int) -> Bool)? = nil,
                    gitWrite: (@Sendable (GitWrite) async -> GitWriteOutcome)? = nil) {
            self.sessions = sessions
            self.session = session
            self.searchSessions = searchSessions
            self.kill = kill
            self.deleteSession = deleteSession
            self.backendName = backendName
            self.globalPause = globalPause
            self.forwardPrWebhook = forwardPrWebhook
            self.gitWrite = gitWrite
        }
    }

    /// One working-tree write, as a remote client asked for it.
    public struct GitWrite: Sendable {
        public enum Kind: String, Sendable {
            case commit, push, revert, commitMessage
        }
        public let kind: Kind
        public let sessionId: String
        /// Another worktree of the same repo, when the client named one.
        public let cwd: String?
        /// The commit message, on `.commit`.
        public let message: String?
        /// The path to discard, on `.revert`.
        public let path: String?
        /// Which hunk of it, when the discard is per-hunk.
        public let hunkIndex: Int?

        public init(kind: Kind, sessionId: String, cwd: String? = nil, message: String? = nil,
                    path: String? = nil, hunkIndex: Int? = nil) {
            self.kind = kind; self.sessionId = sessionId; self.cwd = cwd
            self.message = message; self.path = path; self.hunkIndex = hunkIndex
        }
    }

    /// What the core answered: its JSON payload, or its reason for refusing.
    ///
    /// Never both, and never neither. A write that this relay could not confirm is a
    /// failure, because a 200 for a commit nobody made is the one answer a client
    /// cannot recover from.
    public enum GitWriteOutcome: Sendable {
        case ok(Data)
        case failed(String)
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

    // MARK: - REST (the subset a relay over a remote core can honestly answer)

    static func buildRouter(source: Source, upstreamBaseURL: String) -> Router<BasicRequestContext> {
        let router = Router()

        router.get("/api/health") { _, _ in
            jsonResponse(ProxyHealth(ok: true, core: source.backendName, relayingTo: upstreamBaseURL))
        }

        // The desktop presence gate was tracked by the in-process server, and nothing
        // tracks it now. Said out loud rather than answered with a made-up "nobody is
        // at the desk", which would change how a caller notifies.
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

        // Kill the pty, then tell the core to forget the session.
        //
        // This used to reap the worktree here as well, because "protocol v1 has no
        // frame that tells a core to forget a session". It has one: `sessionDelete`,
        // and the promise behind that capability is all four things — the pty, the
        // row, the conversation's adoptability and the worktree. `deleteSession`
        // sends it, the daemon's registry removes the directory, and a second removal
        // from this process was this relay racing the core it fronts for the same
        // path (juancode-yydd).
        router.delete("/api/sessions/:id") { _, ctx in
            guard let id = ctx.parameters.get("id"), source.session(id) != nil else {
                throw APIError(.notFound, "not found")
            }
            source.kill(id)
            source.deleteSession(id)
            return Response(status: .noContent)
        }

        // The per-session reads, proxied to the daemon verbatim.
        //
        // Not answered here, and deliberately not answered off the desktop's mirror:
        // the mirror is a cache of rows, it holds no transcript at all, and the
        // scrollback it does hold has no record of the width those bytes were parsed
        // at. Replaying a byte ring at the wrong width lands every hard wrap and
        // absolute cursor move in the wrong cell, so the one process that knows the
        // grid is the one that has to answer — and its answer carries `cols`/`rows`
        // through to the client (juancode-ag1e).
        //
        // An allowlist rather than a blanket `/api/sessions/**` proxy: these are the
        // paths the daemon serves, and forwarding the rest would turn an honest 501
        // naming the missing capability into the daemon's bare 404.
        for leaf in sessionReadLeaves {
            router.get("/api/sessions/:id/\(leaf)") { req, ctx -> Response in
                guard let id = ctx.parameters.get("id") else {
                    throw APIError(.notFound, "not found")
                }
                return try await proxyRead(sessionId: id, leaf: leaf, query: req.uri.query,
                                           upstreamBaseURL: upstreamBaseURL,
                                           core: source.backendName)
            }
        }

        // The four working-tree writes. Registered only when the core behind this relay
        // has frames for them, so a core without falls through to the 501 that names
        // what is missing — which is the honest answer for one that would not have
        // committed anything.
        //
        // Same paths and same bodies the Swift core served, so a client that had them
        // before has them again. `file` is the body key for the discard's path because
        // that is what the Swift core's `RevertBody` called it.
        if let write = source.gitWrite {
            router.post("/api/sessions/:id/commit") { req, ctx -> Response in
                let id = try relaySessionId(ctx, source)
                let body = try await req.decode(as: RelayCommitBody.self, context: ctx)
                let message = body.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { throw APIError(.badRequest, "message required") }
                return try await relayGitWrite(write, .init(kind: .commit, sessionId: id,
                                                            cwd: body.cwd, message: message))
            }
            router.post("/api/sessions/:id/push") { req, ctx -> Response in
                let id = try relaySessionId(ctx, source)
                let body = try? await req.decode(as: RelayCwdBody.self, context: ctx)
                return try await relayGitWrite(write, .init(kind: .push, sessionId: id,
                                                            cwd: body?.cwd))
            }
            router.post("/api/sessions/:id/revert") { req, ctx -> Response in
                let id = try relaySessionId(ctx, source)
                let body = try await req.decode(as: RelayRevertBody.self, context: ctx)
                let file = body.file.trimmingCharacters(in: .whitespaces)
                guard !file.isEmpty else { throw APIError(.badRequest, "file required") }
                return try await relayGitWrite(write, .init(kind: .revert, sessionId: id,
                                                            cwd: body.cwd, path: file,
                                                            hunkIndex: body.hunkIndex))
            }
            router.post("/api/sessions/:id/commit-message") { req, ctx -> Response in
                let id = try relaySessionId(ctx, source)
                let body = try? await req.decode(as: RelayCwdBody.self, context: ctx)
                return try await relayGitWrite(write, .init(kind: .commitMessage, sessionId: id,
                                                            cwd: body?.cwd))
            }
        }

        // The webhook fast path. Registered only when the core behind this relay can
        // take the trigger: otherwise the route falls through to the 501 below, which
        // is the honest answer for a core that would have dropped it.
        //
        // The trigger is forwarded and nothing is awaited. `matched` is deliberately
        // absent from the reply the Swift core's own route carries: the count lives on
        // the far side of a fire-and-forget frame, the sidecar never reads it, and a
        // number invented here would be worse than no number.
        if let forward = source.forwardPrWebhook {
            router.post("/api/pr-webhook") { req, ctx -> Response in
                let body = try await req.decode(as: RelayPrWebhookBody.self, context: ctx)
                let repo = body.repo.trimmingCharacters(in: .whitespaces)
                guard !repo.isEmpty, body.number > 0 else {
                    throw APIError(.badRequest, "repo (owner/name) and positive number required")
                }
                guard forward(repo, body.number) else {
                    throw APIError(.notImplemented,
                                   unservedMessage("/api/pr-webhook", core: source.backendName))
                }
                return jsonResponse(RelayPrWebhookResponse(ok: true))
            }
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

    /// The per-session reads the daemon serves and this relay forwards. Kept as one
    /// list so the route table and the proxy cannot drift apart.
    ///
    /// `screen` is the rendered one (juancode-s96g): it is why the byte-log fallback
    /// beside it exists at all, so a relay that forwarded the log and not the picture
    /// would hand every caller the garbling input this route was added to retire.
    ///
    /// The last four are the working tree (juancode-52e8.14.5). They are the same URLs
    /// the Swift core used to serve in-process, so a remote client that had them before
    /// has them again — this time answered by the process that actually holds the
    /// session. The daemon's PATH-addressed git family (`/api/git/…?cwd=`) is
    /// deliberately NOT here: it names a directory rather than a session, it is what
    /// the desktop asks over loopback, and forwarding it would put "read git anywhere
    /// on this machine" on the address the phone reaches.
    static let sessionReadLeaves = [
        "transcript", "messages", "scrollback", "screen",
        "diff", "git", "worktrees", "file",
        // And the review surface's read half (juancode-52e8.14.6), forwarded for the
        // same reason: the sidecar and the phone console are exactly the clients that
        // cannot run a review themselves and have to read the one the daemon cached.
        // The writes go over the socket, where a pass that takes minutes is a frame
        // rather than a request held open.
        "review", "comments",
    ]

    /// The session a relayed write names, confirmed against the mirror first.
    ///
    /// A 404 here rather than letting the frame go out and waiting out its budget: the
    /// mirror is the daemon's own list, so an id it has never heard of is an id the
    /// daemon has not either.
    static func relaySessionId(_ ctx: BasicRequestContext, _ source: Source) throws -> String {
        guard let id = ctx.parameters.get("id"), source.session(id) != nil else {
            throw APIError(.notFound, "not found")
        }
        return id
    }

    /// Run one write and turn its outcome into a response.
    ///
    /// A refusal is a 422 carrying the core's own sentence — git's first useful line,
    /// or "Nothing to commit." — because that text is the whole answer and a status
    /// code alone would make the caller invent one.
    static func relayGitWrite(_ write: @Sendable (GitWrite) async -> GitWriteOutcome,
                              _ request: GitWrite) async throws -> Response {
        switch await write(request) {
        case .ok(let data):
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            return Response(status: .ok, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        case .failed(let reason):
            throw APIError(.unprocessableContent, reason)
        }
    }

    /// Forward one read to the daemon and hand its answer back unchanged.
    ///
    /// Status, body and content type all come from upstream: this hop must not
    /// reinterpret a 404 for a session the daemon has never heard of, and it must not
    /// re-encode a body whose `cols`/`rows` are the point of the response. An
    /// unreachable daemon is a 502 rather than a 501 — the route exists, the core
    /// behind it did not answer.
    static func proxyRead(sessionId: String, leaf: String, query: String?,
                          upstreamBaseURL: String, core: String) async throws -> Response {
        guard var comps = URLComponents(string: upstreamBaseURL) else {
            throw APIError(.internalServerError, "not a usable core URL to relay to: \(upstreamBaseURL)")
        }
        // The segment goes on verbatim, still percent-encoded as it arrived: the router
        // hands back the raw segment, so re-encoding it here would turn a `%2F` into a
        // `%252F` and the daemon would look up a session id nobody has. Encoding and
        // decoding are the client's and the daemon's business, and this hop is neither.
        comps.percentEncodedPath = "/api/sessions/\(sessionId)/\(leaf)"
        comps.percentEncodedQuery = query
        guard let url = comps.url else {
            throw APIError(.internalServerError, "not a usable core URL to relay to: \(upstreamBaseURL)")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw APIError(.badGateway,
                           "the \(core) core did not answer /api/sessions/\(sessionId)/\(leaf): "
                           + errMsg(error))
        }
        let http = response as? HTTPURLResponse
        let status = HTTPResponse.Status(code: http?.statusCode ?? 200)
        var headers = HTTPFields()
        headers[.contentType] = http?.value(forHTTPHeaderField: "Content-Type")
            ?? "application/json; charset=utf-8"
        return Response(status: status, headers: headers,
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// One sentence per unserved endpoint: what is missing and why, in the terms
    /// the rest of the app uses for a capability a core does not have.
    static func unservedMessage(_ path: String, core: String) -> String {
        let reason: String
        switch path {
        case "/api/pr-webhook":
            reason = "this core has no frame for a webhook trigger, so the trigger would be "
                + "dropped and the watch list would wait for its next poll"
        case "/api/tracked-prs":
            reason = "PR tracking runs in the desktop's own core, which this launch is not using"
        case "/presence":
            reason = "desktop presence is tracked by the in-process core, which this launch is not using"
        default:
            reason = "it needs the in-process core's registry, which this launch is not using"
        }
        return "\(path) is not served with the \(core) core: \(reason)."
    }
}

/// Body of the relay's `POST /api/pr-webhook`: the repo the event names and the PR
/// number in it. The event itself never crosses the relay — the core re-reads the PR
/// through `gh` — so this is the whole of what a webhook is worth forwarding.
struct RelayPrWebhookBody: Decodable { let repo: String; let number: Int }

/// The bodies of the four relayed working-tree writes — the same shapes the Swift
/// core's own routes decoded, so a client's request does not change with the core.
struct RelayCwdBody: Decodable { let cwd: String? }
struct RelayCommitBody: Decodable { let message: String; let cwd: String? }
struct RelayRevertBody: Decodable { let file: String; let hunkIndex: Int?; let cwd: String? }

/// Its reply. No `matched`: see the route.
struct RelayPrWebhookResponse: Encodable { let ok: Bool }

/// `/api/health` on the relay says which core answers and where its ptys live, so
/// a bug report is never ambiguous about which process was in play.
struct ProxyHealth: Encodable {
    let ok: Bool
    let core: String
    let relayingTo: String
}
