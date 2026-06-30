import XCTest
@testable import JuancodePersistence
import JuancodeCore

/// SQLite-backed message-queue tests (oracle-cj3 / juancode-r82): GRDBStore conforms
/// to `MessageQueuePersistence`, so the queue survives restarts and is dropped with
/// its session. Mirrors the `messageQueueDb` coverage in apps/server's db tests.
final class MessageQueueStoreTests: XCTestCase {
    private var path: String!
    private var store: GRDBStore!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() as NSString
        path = dir.appendingPathComponent("juancode-mq-test-\(UUID().uuidString).db")
        store = try GRDBStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func meta(_ id: String) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: "/tmp/work", title: "Claude · juancode",
            status: .running, exitCode: nil, createdAt: nowMs(), updatedAt: nowMs(),
            cliSessionId: nil, skipPermissions: false, worktreePath: nil, usage: nil
        )
    }

    func testAddListPeekRemoveInInsertionOrder() {
        let s = "session-1"
        let a = store.add(s, text: "first")
        _ = store.add(s, text: "second")
        let c = store.add(s, text: "third")

        XCTAssertEqual(store.list(s).map(\.text), ["first", "second", "third"])
        XCTAssertEqual(store.first(s)?.id, a.id)

        XCTAssertTrue(store.remove(s, a.id))
        XCTAssertEqual(store.first(s)?.id, store.list(s).first?.id)
        XCTAssertEqual(store.list(s).map(\.text), ["second", "third"])
        XCTAssertEqual(store.list(s).last?.id, c.id)
    }

    func testIsolatesQueuesPerSession() {
        store.add("A", text: "a-msg")
        store.add("B", text: "b-msg")
        XCTAssertEqual(store.list("A").map(\.text), ["a-msg"])
        XCTAssertEqual(store.list("B").map(\.text), ["b-msg"])
        let aItem = store.list("A")[0]
        XCTAssertFalse(store.remove("B", aItem.id)) // wrong session → no-op
        XCTAssertEqual(store.list("A").count, 1)
    }

    func testQueueSurvivesReopen() throws {
        let s = "persisted"
        store.add(s, text: "kept")
        // Reopen the same file: the row is still there.
        let reopened = try GRDBStore(path: path)
        XCTAssertEqual(reopened.list(s).map(\.text), ["kept"])
    }

    func testDeletingSessionClearsItsQueue() {
        let m = meta("with-queue")
        store.insert(m)
        store.add(m.id, text: "doomed")
        XCTAssertEqual(store.list(m.id).count, 1)
        XCTAssertTrue(store.delete(m.id))
        XCTAssertTrue(store.list(m.id).isEmpty)
    }
}
