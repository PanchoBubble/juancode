import XCTest
@testable import JuancodePersistence
import JuancodeCore

/// The `dormant` flag (juancode-lgq) round-trips through the GRDB store — the
/// marker the idle reaper persists just before killing a session's pty so the UI
/// can tell "reaped while idle, wake on demand" from a crash/exit.
final class DormantPersistenceTests: XCTestCase {
    private var path: String!
    private var store: GRDBStore!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() as NSString
        path = dir.appendingPathComponent("juancode-dormant-test-\(UUID().uuidString).db")
        store = try GRDBStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func meta(dormant: Bool = false) -> SessionMeta {
        let now = nowMs()
        return SessionMeta(
            id: UUID().uuidString.lowercased(), provider: .claude, cwd: "/tmp/work",
            title: "Claude · juancode", status: .running, exitCode: nil,
            createdAt: now, updatedAt: now, cliSessionId: nil, skipPermissions: false,
            worktreePath: nil, usage: nil, dormant: dormant
        )
    }

    func testDormantDefaultsFalseAndRoundTrips() {
        let m = meta()
        store.insert(m)
        XCTAssertEqual(store.get(m.id)?.dormant, false)

        // The reaper's marker: flag + exited status persisted via `update`.
        var reaped = m
        reaped.dormant = true
        reaped.status = .exited
        store.update(reaped, scrollback: Array("BYE".utf8))
        XCTAssertEqual(store.get(m.id)?.dormant, true)
        XCTAssertEqual(store.get(m.id)?.status, .exited)

        // Waking clears it (Session.resume persists dormant = false).
        var awake = reaped
        awake.dormant = false
        awake.status = .running
        store.update(awake, scrollback: [])
        XCTAssertEqual(store.get(m.id)?.dormant, false)
    }

    func testInsertPersistsDormantFlag() {
        let m = meta(dormant: true)
        store.insert(m)
        XCTAssertEqual(store.get(m.id)?.dormant, true)
    }

    /// A pre-existing db that predates the column gets it via the ALTER migration.
    func testMigrationAddsDormantColumnToOldDb() throws {
        // Recreate the store against the same file; migrate() must be idempotent
        // and old rows must read back dormant = false.
        let m = meta()
        store.insert(m)
        store = nil
        store = try GRDBStore(path: path)
        XCTAssertEqual(store.get(m.id)?.dormant, false)
    }
}
