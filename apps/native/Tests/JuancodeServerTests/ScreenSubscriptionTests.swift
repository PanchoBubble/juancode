import XCTest
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// Capability negotiation for the rendered-screen stream (juancode-a2h.3): screen
/// frames are strictly opt-in per connection — a client that never sends
/// `subscribeScreen` gets exactly the pre-existing byte-stream behaviour.
final class ScreenSubscriptionTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-screen-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    /// Build a connection whose sent frames are captured, run `body` against it,
    /// then return every ServerMessage it emitted (as parsed JSON objects).
    private func drive(
        _ body: (WebSocketConnection, AppState) async -> Void
    ) async throws -> [[String: Any]] {
        let state = try AppState(dbPath: dbPath)
        let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
        let conn = WebSocketConnection(state: state, gate: WSSendGate(cont: cont))
        await body(conn, state)
        conn.stopOutput()
        conn.close()
        cont.finish()
        var out: [[String: Any]] = []
        for await msg in stream {
            if let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }

    private static func exitedMeta(_ id: String) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: "t", status: .exited,
                    exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(), cliSessionId: nil,
                    skipPermissions: false, worktreePath: nil, usage: nil)
    }

    func testAttachWithoutOptInEmitsNoScreenFrames() async throws {
        let frames = try await drive { conn, state in
            state.store.insert(Self.exitedMeta("s-1"))
            await conn.handle(.attach(sessionId: "s-1", cols: 80, rows: 24))
        }
        let types = frames.map { $0["type"] as? String }
        XCTAssertTrue(types.contains("attached"), "the byte-path attach reply is unchanged")
        XCTAssertTrue(types.contains("exit"))
        XCTAssertFalse(types.contains("screen"),
                       "no subscribeScreen ⇒ no screen frames, byte behaviour only")
    }

    func testSubscribeScreenForDeadSessionErrors() async throws {
        // The model lives with the pty; a dead session has no screen to stream, so
        // the opt-in is answered with an error rather than a silent nothing.
        let frames = try await drive { conn, state in
            state.store.insert(Self.exitedMeta("s-1"))
            await conn.handle(.subscribeScreen(sessionId: "s-1"))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["type"] as? String, "error")
        XCTAssertEqual(frames[0]["sessionId"] as? String, "s-1")
    }

    func testSubscribeScreenForUnknownSessionErrors() async throws {
        let frames = try await drive { conn, _ in
            await conn.handle(.subscribeScreen(sessionId: "nope"))
        }
        XCTAssertEqual(frames.first?["type"] as? String, "error")
    }
}
