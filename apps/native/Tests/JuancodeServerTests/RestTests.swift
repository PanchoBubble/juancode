import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// REST endpoint coverage for the embedded server (juancode-u34.3), driven
/// through Hummingbird's in-process `.router` test framework (no live socket).
/// The WS session flow is covered by the headless end-to-end check.
final class RestTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-rest-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    /// Spin up an app backed by a fresh store and run `body` against it.
    private func withServer(
        _ body: @escaping @Sendable (any TestClientProtocol, GRDBStore) async throws -> Void
    ) async throws {
        let state = try AppState(dbPath: dbPath)
        let app = Application(router: JuancodeServer.buildRouter(state: state, webDist: nil))
        try await app.test(.router) { client in try await body(client, state.store) }
    }

    // Pure helpers — `static` so the @Sendable test closures don't capture self.
    private static func sampleMeta(_ id: String, title: String = "Claude · work") -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: title, status: .exited,
                    exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(), cliSessionId: "cli-\(id)",
                    skipPermissions: false, worktreePath: nil, usage: nil)
    }

    private static func json(_ res: TestResponse) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView), options: [.fragmentsAllowed])
    }

    func testHealth() async throws {
        try await withServer { client, _ in
            try await client.execute(uri: "/api/health", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["ok"] as? Bool, true)
            }
        }
    }

    func testProviders() async throws {
        try await withServer { client, _ in
            try await client.execute(uri: "/api/providers", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                let ids = (Self.json(res) as? [[String: Any]])?.compactMap { $0["id"] as? String }
                XCTAssertEqual(ids, ["claude", "codex"])
            }
        }
    }

    func testSessionsListAndGet() async throws {
        try await withServer { client, store in
            try await client.execute(uri: "/api/sessions", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 0)
            }
            store.insert(Self.sampleMeta("s1"))
            try await client.execute(uri: "/api/sessions", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 1)
            }
            try await client.execute(uri: "/api/sessions/s1", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["id"] as? String, "s1")
            }
            try await client.execute(uri: "/api/sessions/nope", method: .get) { res in
                XCTAssertEqual(res.status, .notFound)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["error"] as? String, "not found")
            }
        }
    }

    func testSearchShortQueryIsEmpty() async throws {
        try await withServer { client, store in
            store.insert(Self.sampleMeta("s1", title: "deploy pipeline"))
            try await client.execute(uri: "/api/search?q=a", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 0)
            }
            try await client.execute(uri: "/api/search?q=deploy", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 1)
            }
        }
    }

    func testCommentsLifecycle() async throws {
        try await withServer { client, store in
            store.insert(Self.sampleMeta("s1"))
            let body = ByteBuffer(string: #"{"file":"a.ts","side":"new","line":3,"body":"look here"}"#)
            try await client.execute(uri: "/api/sessions/s1/comments", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { res in
                XCTAssertEqual(res.status, .created)
                XCTAssertEqual((Self.json(res) as? [String: Any])?["file"] as? String, "a.ts")
            }
            try await client.execute(uri: "/api/sessions/s1/comments", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 1)
            }
            try await client.execute(uri: "/api/sessions/s1/comments", method: .delete) { res in
                XCTAssertEqual(res.status, .noContent)
            }
            try await client.execute(uri: "/api/sessions/s1/comments", method: .get) { res in
                XCTAssertEqual((Self.json(res) as? [Any])?.count, 0)
            }
        }
    }

    func testReviewNullWhenNone() async throws {
        try await withServer { client, store in
            store.insert(Self.sampleMeta("s1"))
            try await client.execute(uri: "/api/sessions/s1/review", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(Self.json(res) is NSNull)
            }
        }
    }

    func testDeleteSession() async throws {
        try await withServer { client, store in
            store.insert(Self.sampleMeta("s1"))
            try await client.execute(uri: "/api/sessions/s1", method: .delete) { res in
                XCTAssertEqual(res.status, .noContent)
            }
            XCTAssertNil(store.get("s1"))
            try await client.execute(uri: "/api/sessions/s1", method: .delete) { res in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }
}
