import XCTest
@testable import JuancodeServices

/// The Oracle control dir's on-disk protocol (juancode-a2s7): path layout, the
/// durable dispatch-outcome log, the persisted mailbox offsets, and the dedup
/// ledger. The rest of `OracleTests` moved to `JuancodeDesktopTests` with the
/// desktop-local half of Oracle. The control dir is pointed at a fresh temp dir via
/// `JUANCODE_ORACLE_DIR` so nothing touches `~/.juancode`.
final class OracleMailboxTests: XCTestCase {
    private var dir: String = ""

    override func setUpWithError() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        dir = path
        setenv("JUANCODE_ORACLE_DIR", path, 1)
        // Start with an empty mailbox, as bootstrap would.
        FileManager.default.createFile(atPath: OraclePaths.dispatchFile, contents: Data())
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_ORACLE_DIR")
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testPathsRootAtControlDir() {
        XCTAssertEqual(OraclePaths.controlDir, dir)
        XCTAssertTrue(OraclePaths.dispatchFile.hasSuffix("dispatch.jsonl"))
        XCTAssertTrue(OraclePaths.stateFile.hasSuffix("state.json"))
        XCTAssertTrue(OraclePaths.beadsDir.hasSuffix(".beads"))
    }

    func testMailboxOffsetPersistsAndRoundTrips() {
        // Absent file → nil, so the caller primes to EOF exactly once.
        XCTAssertNil(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile))
        writeOracleMailboxOffset(42, at: OraclePaths.dispatchOffsetFile)
        XCTAssertEqual(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile), 42)
        writeOracleMailboxOffset(0, at: OraclePaths.dispatchOffsetFile)
        XCTAssertEqual(readOracleMailboxOffset(at: OraclePaths.dispatchOffsetFile), 0)
        // Corrupt content degrades to nil (re-prime), never a crash or bogus offset.
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: OraclePaths.askOffsetFile))
        XCTAssertNil(readOracleMailboxOffset(at: OraclePaths.askOffsetFile))
    }

    func testDispatchResultAppendAndReadRoundTrips() throws {
        try appendOracleDispatchResult(OracleDispatchResult(
            dispatchId: "d-1", project: "/a", ok: false,
            error: "\"/a\" is not an existing directory", at: 100))
        try appendOracleDispatchResult(OracleDispatchResult(
            dispatchId: nil, project: "/b", ok: true, sessionId: "s-9", at: 200))

        let (results, offset) = readOracleDispatchResults(since: 0)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].dispatchId, "d-1")
        XCTAssertEqual(results[0].ok, false)
        XCTAssertEqual(results[0].error, "\"/a\" is not an existing directory")
        XCTAssertNil(results[1].dispatchId)
        XCTAssertEqual(results[1].sessionId, "s-9")
        // Incremental like the mailboxes: nothing new from the returned offset.
        XCTAssertTrue(readOracleDispatchResults(since: offset).results.isEmpty)
    }

    func testDispatchLedgerClaimsExactlyOnce() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        let ledger = OracleDispatchLedger(path: { path })
        XCTAssertTrue(ledger.claim("d-1"))
        XCTAssertFalse(ledger.claim("d-1")) // the double-spawn guard
        XCTAssertTrue(ledger.claim("d-2"))
    }

    func testDispatchLedgerPersistsAcrossInstances() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        XCTAssertTrue(OracleDispatchLedger(path: { path }).claim("d-1"))
        // A fresh instance (≈ app relaunch) still refuses the processed id, so a
        // replayed mailbox line can't start the dispatch a second time.
        let reloaded = OracleDispatchLedger(path: { path })
        XCTAssertFalse(reloaded.claim("d-1"))
        XCTAssertTrue(reloaded.claim("d-2"))
    }

    func testDispatchLedgerEvictsOldestPastCapacity() {
        let path = (dir as NSString).appendingPathComponent("ledger.json")
        let ledger = OracleDispatchLedger(capacity: 2, path: { path })
        XCTAssertTrue(ledger.claim("d-1"))
        XCTAssertTrue(ledger.claim("d-2"))
        XCTAssertTrue(ledger.claim("d-3")) // evicts d-1
        XCTAssertFalse(ledger.claim("d-3"))
        XCTAssertFalse(ledger.claim("d-2"))
        XCTAssertTrue(ledger.claim("d-1")) // evicted → claimable again (bounded memory)
    }
}
