import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// `POST /api/sessions/:id/wait` (juancode-9umy) — the HTTP surface of the wait
/// primitive. The engine's own outcomes are covered by `SessionWaitTests`; what
/// is checked here is the request contract: validation, and the two outcomes a
/// route can produce without a live pty.
final class WaitRouteTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-wait-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private func withServer(
        _ body: @escaping @Sendable (any TestClientProtocol, GRDBStore) async throws -> Void
    ) async throws {
        let state = try AppState(dbPath: dbPath)
        let app = Application(router: JuancodeServer.buildRouter(state: state, webDist: nil))
        try await app.test(.router) { client in try await body(client, state.store) }
    }

    private static func json(_ res: TestResponse) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))) as? [String: Any]
    }

    private static func post(_ client: any TestClientProtocol, _ id: String, _ body: String,
                             _ check: @escaping @Sendable (TestResponse) -> Void) async throws {
        try await client.execute(uri: "/api/sessions/\(id)/wait", method: .post,
                                 headers: [.contentType: "application/json"],
                                 body: ByteBuffer(string: body)) { res in check(res) }
    }

    /// An id nobody has ever seen is `session_gone`, not a timeout — and the 404
    /// carries the same body shape, so a caller reads `outcome` either way.
    func testUnknownSessionIsGone() async throws {
        try await withServer { client, _ in
            try await Self.post(client, "nope", #"{"idleMs":10}"#) { res in
                XCTAssertEqual(res.status, .notFound)
                XCTAssertEqual(Self.json(res)?["outcome"] as? String, "session_gone")
            }
        }
    }

    /// A session the store knows but the registry doesn't hold is not running, so
    /// waiting on its screen can only ever be `session_exited` — reported straight
    /// away rather than after the full timeout.
    func testKnownButNotLiveSessionIsExited() async throws {
        try await withServer { client, store in
            store.insert(SessionMeta(id: "s1", provider: .claude, cwd: "/tmp", title: "t",
                                     status: .exited, exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(),
                                     cliSessionId: nil, skipPermissions: false, worktreePath: nil, usage: nil))
            let started = nowMs()
            try await Self.post(client, "s1", #"{"text":"never","timeout":"1m"}"#) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(Self.json(res)?["outcome"] as? String, "session_exited")
            }
            XCTAssertLessThan(nowMs() - started, 5_000)
        }
    }

    func testValidationRejectsAmbiguousRequests() async throws {
        try await withServer { client, _ in
            for body in ["{}", #"{"text":""}"#, #"{"text":"a","idleMs":5}"#,
                         #"{"idleMs":5,"timeoutMs":0}"#, #"{"idleMs":5,"timeout":"soon"}"#] {
                try await Self.post(client, "nope", body) { res in
                    XCTAssertEqual(res.status, .badRequest, "body: \(body)")
                    XCTAssertNotNil(Self.json(res)?["error"] as? String)
                }
            }
        }
    }
}
