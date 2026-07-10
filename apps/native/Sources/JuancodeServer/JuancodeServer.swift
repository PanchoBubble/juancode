import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// The embedded HTTP + WebSocket server (juancode-u34.3). Serves the protocol.ts
/// wire format over `/ws` (mirrors ws.ts) and the REST endpoints (mirrors
/// index.ts) so the existing React web app works as a remote client unchanged.
public enum JuancodeServer {
    /// Build and run the server until shutdown. `webDist`, when present, is served
    /// as the built web app (production); in dev the Vite server proxies instead.
    /// - Parameter handleSignals: when true (headless runner) the server traps
    ///   SIGINT/SIGTERM for graceful shutdown. The GUI app passes false — it owns
    ///   its own lifecycle (Cmd-Q), and trapping SIGINT there would swallow the
    ///   terminal's Ctrl-C without quitting the process.
    public static func run(
        state: AppState,
        host: String = Config.bindHost,
        port: Int = Config.port,
        webDist: String? = nil,
        handleSignals: Bool = true
    ) async throws {
        let router = buildRouter(state: state, webDist: webDist)
        let wsRouter = buildWSRouter(state: state)
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname(host, port: port), serverName: "juancode")
        )
        if handleSignals {
            try await app.runService()
        } else {
            try await app.runService(gracefulShutdownSignals: [])
        }
    }

    // MARK: - WebSocket router (/ws)

    static func buildWSRouter(state: AppState) -> Router<BasicWebSocketRequestContext> {
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { inbound, outbound, _ in
            // Server→client messages are produced from many threads (pty output,
            // activity); funnel them through a stream that one writer task drains.
            let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
            // The send gate tracks queued-but-unwritten frames so the connection's
            // output coalescer can detect a stalled client and stop growing this
            // stream without bound (juancode-5qw.7).
            let gate = WSSendGate(cont: cont)
            let conn = WebSocketConnection(state: state, gate: gate)
            conn.start()
            // Announce version + capabilities first, before any pty output, so
            // clients can feature-detect (juancode-tgc). Yielded onto the same
            // stream the writer drains, so it's the first frame on the wire.
            conn.send(.serverInfo(protocolVersion: WireProtocol.version,
                                  capabilities: WireProtocol.capabilities))
            let writer = Task {
                for await msg in stream {
                    try? await outbound.writeTextMessage(msg.jsonString())
                    // Mark the frame drained so the gate's backpressure signal
                    // clears once the client catches up (juancode-5qw.7).
                    gate.didWrite()
                }
            }
            defer {
                conn.stopOutput()
                conn.close()
                cont.finish()
                writer.cancel()
            }
            for try await frame in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let text) = frame else { continue }
                guard let data = text.data(using: .utf8),
                      let msg = try? JSONDecoder().decode(ClientMessage.self, from: data) else {
                    conn.send(.error(sessionId: nil, message: "Invalid JSON"))
                    continue
                }
                await conn.handle(msg)
            }
        }
        return wsRouter
    }

    // MARK: - HTTP router (REST, mirrors index.ts)

    static func buildRouter(state: AppState, webDist: String?) -> Router<BasicRequestContext> {
        let router = Router()
        let store = state.store

        // Serve the built web app in production (apps/web/dist), if present.
        if let webDist, FileManager.default.fileExists(atPath: webDist) {
            router.add(middleware: FileMiddleware(webDist, searchForIndexHtml: true))
        }

        router.get("/api/health") { _, _ in jsonResponse(["ok": true]) }

        // Desktop presence (juancode-2zp): the app reports frontmost/resign so the
        // oracle-mcp push gate can stay quiet on the phone while the user is at the
        // desk. `active` = updated within the last ~15s (frontmost right now).
        router.get("/presence") { _, _ in
            let last = state.desktopLastActiveMs
            let active = last.map { nowMs() - $0 <= 15_000 } ?? false
            return jsonResponse(PresenceResponse(active: active, lastActiveMs: last))
        }

        router.get("/api/providers") { _, _ in
            ProviderId.allCases.map { ProviderInfo(id: $0.rawValue, label: Providers.spec(for: $0).label) }
        }

        router.get("/api/status") { _, _ in await getAllStatus() }

        router.get("/api/sessions") { _, _ in store.list() }

        // Full-text search over titles + scrollback. <2 chars → empty list.
        router.get("/api/search") { req, _ in
            let q = (req.uri.queryParameters["q"].map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            return q.count < 2 ? [SearchHit]() : store.search(q, limit: 50)
        }

        router.get("/api/sessions/:id") { _, ctx in
            try meta(ctx, store)
        }

        // Permanently delete a session: kill its pty, drop from sqlite, remove
        // its auto-created worktree (best-effort).
        router.delete("/api/sessions/:id") { _, ctx in
            let id = try param(ctx, "id")
            let m = store.get(id)
            state.registry.get(id)?.kill()
            guard store.delete(id) else { throw APIError(.notFound, "not found") }
            if let wt = m?.worktreePath {
                try? await removeWorktree(wt)
            }
            return Response(status: .noContent)
        }

        router.get("/api/sessions/:id/diff") { req, ctx in
            let m = try meta(ctx, store)
            let cwd = await resolveTargetCwd(m.cwd, req.uri.queryParameters["cwd"].map(String.init))
            do { return try await getDiff(cwd) }
            catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.get("/api/sessions/:id/git") { req, ctx in
            let m = try meta(ctx, store)
            return await getGitState(await resolveTargetCwd(m.cwd, req.uri.queryParameters["cwd"].map(String.init)))
        }

        router.post("/api/sessions/:id/commit-message") { req, ctx in
            let m = try meta(ctx, store)
            let body = try? await req.decode(as: CwdBody.self, context: ctx)
            do {
                let cwd = await resolveTargetCwd(m.cwd, body?.cwd)
                let diff = try await getDiff(cwd)
                return CommitMessageResult(message: try await generateCommitMessage(cwd, diff.files))
            } catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.post("/api/sessions/:id/commit") { req, ctx in
            let m = try meta(ctx, store)
            let body = try await req.decode(as: CommitBody.self, context: ctx)
            let message = body.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { throw APIError(.badRequest, "message required") }
            let cwd = await resolveTargetCwd(m.cwd, body.cwd)
            do { return try await commitAll(cwd, message) }
            catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.post("/api/sessions/:id/push") { req, ctx in
            let m = try meta(ctx, store)
            let body = try? await req.decode(as: CwdBody.self, context: ctx)
            let cwd = await resolveTargetCwd(m.cwd, body?.cwd)
            do { return try await pushCurrent(cwd) }
            catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.post("/api/sessions/:id/pr") { req, ctx in
            let m = try meta(ctx, store)
            let body = try await req.decode(as: PrBody.self, context: ctx)
            let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw APIError(.badRequest, "title required") }
            let cwd = await resolveTargetCwd(m.cwd, body.cwd)
            do {
                _ = try await pushCurrent(cwd) // ensure the branch is on the remote first
                return try await createPr(cwd, title: title, body: body.body ?? "", draft: body.draft ?? false)
            } catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.get("/api/sessions/:id/worktrees") { _, ctx in
            let m = try meta(ctx, store)
            return await listWorktrees(m.cwd)
        }

        router.get("/api/sessions/:id/file") { req, ctx in
            let m = try meta(ctx, store)
            guard let rel = req.uri.queryParameters["path"].map(String.init), !rel.isEmpty else {
                throw APIError(.badRequest, "path required")
            }
            let root = URL(fileURLWithPath: m.cwd).standardizedFileURL
            let full = URL(fileURLWithPath: rel, relativeTo: root).standardizedFileURL
            guard full.path == root.path || full.path.hasPrefix(root.path + "/") else {
                throw APIError(.badRequest, "path escapes working dir")
            }
            guard let content = try? String(contentsOfFile: full.path, encoding: .utf8) else {
                throw APIError(.notFound, "could not read file")
            }
            return FileContentResponse(path: rel, content: content)
        }

        router.get("/api/prs") { req, _ in
            guard let cwd = req.uri.queryParameters["cwd"].map(String.init), !cwd.isEmpty else {
                throw APIError(.badRequest, "cwd required")
            }
            return await getOpenPrs(cwd)
        }

        // Tracked-PR registry snapshot (juancode-bt2). The live surface is the WS
        // `subscribeTrackedPrs`/`trackedPrs` pair; this gives the remote client an
        // initial list for TanStack Query without opening the socket first.
        router.get("/api/tracked-prs") { _, _ in
            jsonResponse(await state.prTracking.list().map(TrackedPrWire.init))
        }

        router.get("/api/sessions/:id/beads") { _, ctx in
            let m = try meta(ctx, store)
            return await getBeads(m.cwd)
        }

        router.get("/api/sessions/:id/review") { _, ctx in
            _ = try meta(ctx, store)
            let id = try param(ctx, "id")
            guard let review = store.getReview(id) else { return jsonNullResponse }
            return jsonResponse(review)
        }

        router.post("/api/sessions/:id/review") { _, ctx in
            let m = try meta(ctx, store)
            let id = try param(ctx, "id")
            do {
                let diff = try await getDiff(m.cwd)
                let result = await runReview(cwd: m.cwd, files: diff.files,
                                             comments: store.listComments(id), now: nowMs())
                store.saveReview(id, result)
                return jsonResponse(result)
            } catch { throw APIError(.internalServerError, errMsg(error)) }
        }

        router.get("/api/sessions/:id/comments") { _, ctx in
            _ = try meta(ctx, store)
            return store.listComments(try param(ctx, "id"))
        }

        router.post("/api/sessions/:id/comments") { req, ctx in
            _ = try meta(ctx, store)
            let id = try param(ctx, "id")
            let body = try await req.decode(as: CommentBody.self, context: ctx)
            guard body.side == "old" || body.side == "new",
                  !body.body.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw APIError(.badRequest, "file, side ('old'|'new'), integer line, and body required")
            }
            let end = body.endLine ?? body.line
            let comment = DiffComment(
                id: UUID().uuidString, sessionId: id, file: body.file,
                side: body.side == "old" ? .old : .new,
                line: min(body.line, end), endLine: max(body.line, end),
                body: body.body.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: nowMs()
            )
            store.addComment(comment)
            return jsonResponse(comment, status: .created)
        }

        router.delete("/api/sessions/:id/comments") { _, ctx in
            _ = try meta(ctx, store)
            store.clearComments(try param(ctx, "id"))
            return Response(status: .noContent)
        }

        router.delete("/api/sessions/:id/comments/:commentId") { _, ctx in
            let id = try param(ctx, "id")
            let commentId = try param(ctx, "commentId")
            guard store.removeComment(id, commentId) else { throw APIError(.notFound, "not found") }
            return Response(status: .noContent)
        }

        router.post("/api/uploads") { req, ctx in
            var req = req
            let buf = try await req.collectBody(upTo: 100 * 1024 * 1024)
            let bytes = Data(buf.readableBytesView)
            guard !bytes.isEmpty else { throw APIError(.badRequest, "empty upload") }
            let name = safeUploadName(req.uri.queryParameters["name"].map(String.init) ?? "")
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("juancode-uploads")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("\(String(UUID().uuidString.prefix(8)).lowercased())-\(name)")
            do { try bytes.write(to: URL(fileURLWithPath: path)) }
            catch { throw APIError(.internalServerError, errMsg(error)) }
            return UploadResponse(path: path)
        }

        router.get("/api/dirs") { req, _ in
            let path = URL(fileURLWithPath:
                (req.uri.queryParameters["path"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }) ?? Config.defaultCwd
            ).standardizedFileURL.path
            let query = (req.uri.queryParameters["q"].map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            let parent = (path as NSString).deletingLastPathComponent
            let base = DirsBase(path: path, parent: parent == path ? nil : parent)
            if !query.isEmpty {
                return DirsResponse(path: base.path, parent: base.parent, entries: searchDirs(path, query), search: true)
            }
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: path) else {
                throw APIError(.badRequest, "could not read directory")
            }
            let entries = names.filter { !$0.hasPrefix(".") }
                .filter { isDir((path as NSString).appendingPathComponent($0)) }
                .map { DirEntry(name: $0, path: (path as NSString).appendingPathComponent($0)) }
                .sorted { $0.name.localizedCompare(b: $1.name) }
            return DirsResponse(path: base.path, parent: base.parent, entries: entries, search: false)
        }

        return router
    }
}

// MARK: - request helpers

private func param(_ ctx: BasicRequestContext, _ name: String) throws -> String {
    guard let v = ctx.parameters.get(name) else { throw APIError(.badRequest, "missing \(name)") }
    return v
}

private func meta(_ ctx: BasicRequestContext, _ store: GRDBStore) throws -> SessionMeta {
    guard let m = store.get(try param(ctx, "id")) else { throw APIError(.notFound, "not found") }
    return m
}

/// Resolve which worktree a diff/git-action targets: the session's own cwd by
/// default; an optional requested path selects another worktree of the same repo,
/// validated against the repo's worktree list. Mirrors `resolveTargetCwd`.
private func resolveTargetCwd(_ baseCwd: String, _ requested: String?) async -> String {
    guard let req = requested, !req.isEmpty,
          URL(fileURLWithPath: req).standardizedFileURL.path != URL(fileURLWithPath: baseCwd).standardizedFileURL.path
    else { return baseCwd }
    let match = await listWorktrees(baseCwd).first {
        URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: req).standardizedFileURL.path
    }
    return match?.path ?? baseCwd
}

private func isDir(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

/// Directories we never descend into when searching — noisy and rarely a cwd.
private let searchSkip: Set<String> = ["node_modules", "dist", "build", "coverage", "vendor", "target"]

/// Bounded, depth-limited recursive search for directories whose name matches
/// `query` under `root`. Mirrors `searchDirs` in index.ts.
private func searchDirs(_ root: String, _ query: String, limit: Int = 200, maxDepth: Int = 6) -> [DirEntry] {
    let q = query.lowercased()
    var results: [DirEntry] = []
    var stack: [(dir: String, depth: Int)] = [(root, 0)]
    let fm = FileManager.default
    while let (dir, depth) = stack.popLast(), results.count < limit {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names {
            if name.hasPrefix(".") || searchSkip.contains(name) { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            guard isDir(full) else { continue }
            if name.lowercased().contains(q) {
                let rel = full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : name
                results.append(DirEntry(name: rel, path: full))
            }
            if depth < maxDepth { stack.append((full, depth + 1)) }
        }
    }
    return results.sorted { $0.name.localizedCompare(b: $1.name) }
}

private func safeUploadName(_ raw: String) -> String {
    let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    var cleaned = base.unicodeScalars.map { scalar -> Character in
        let c = Character(scalar)
        return (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "_"
    }
    while cleaned.first == "." { cleaned.removeFirst() }
    let s = String(cleaned.suffix(128))
    return s.isEmpty ? "file" : s
}

private extension String {
    // Stable, case/locale-aware ordering like the TS localeCompare.
    func localizedCompare(b: String) -> Bool { self.localizedCaseInsensitiveCompare(b) == .orderedAscending }
}

// MARK: - request/response DTOs

struct ProviderInfo: Codable, ResponseEncodable { let id: String; let label: String }
struct PresenceResponse: Codable, ResponseEncodable { let active: Bool; let lastActiveMs: Int? }
struct CwdBody: Decodable { let cwd: String? }
struct CommitBody: Decodable { let message: String; let cwd: String? }
struct PrBody: Decodable { let title: String; let body: String?; let draft: Bool?; let cwd: String? }
struct CommentBody: Decodable { let file: String; let side: String; let line: Int; let endLine: Int?; let body: String }
struct FileContentResponse: Codable, ResponseEncodable { let path: String; let content: String }
struct UploadResponse: Codable, ResponseEncodable { let path: String }
struct DirEntry: Codable { let name: String; let path: String }
struct DirsBase { let path: String; let parent: String? }
struct DirsResponse: Codable, ResponseEncodable {
    let path: String; let parent: String?; let entries: [DirEntry]; let search: Bool
}
