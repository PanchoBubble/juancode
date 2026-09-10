import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The read side of the sidecar's dispatch registry (juancode-wn64). The file is
/// written by another process, so every case here is about tolerating what that
/// process might leave behind. `JUANCODE_ORACLE_DIR` points the control dir at a
/// temp dir so nothing touches `~/.juancode`.
final class OracleDispatchRegistryTests: XCTestCase {
    private var dir: String = ""

    override func setUpWithError() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        dir = path
        setenv("JUANCODE_ORACLE_DIR", path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JUANCODE_ORACLE_DIR")
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: oracleDispatchRegistryFile))
    }

    func testMissingFileIsEmpty() {
        XCTAssertTrue(readOracleDispatchRegistry().isEmpty)
    }

    func testCorruptFileIsEmpty() throws {
        try write("not json at all")
        XCTAssertTrue(readOracleDispatchRegistry().isEmpty)
    }

    func testNewestFirstAndLimited() throws {
        let records = (1...5).map { i in
            """
            {"dispatchId":"d\(i)","project":"/p","prompt":"p\(i)","provider":"claude",
             "worktree":true,"telegramChatId":null,"outcome":"started",
             "sessionId":"s\(i)","error":null,"at":\(i)}
            """
        }
        try write("[\(records.joined(separator: ","))]")
        let all = readOracleDispatchRegistry()
        XCTAssertEqual(all.map(\.dispatchId), ["d5", "d4", "d3", "d2", "d1"])
        XCTAssertEqual(readOracleDispatchRegistry(limit: 2).map(\.dispatchId), ["d5", "d4"])
    }

    /// One record the sidecar wrote in a shape we don't recognise must not lose the
    /// rest of the file — each element is decoded on its own.
    func testOneBadRecordDoesNotLoseTheOthers() throws {
        try write("""
        [{"nope":1},
         {"dispatchId":"good","project":"/p","prompt":"do juancode-abc","provider":"codex",
          "worktree":false,"telegramChatId":7,"outcome":"rejected","sessionId":null,
          "error":"no such dir","at":42}]
        """)
        let all = readOracleDispatchRegistry()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].dispatchId, "good")
        XCTAssertEqual(all[0].outcome, "rejected")
        XCTAssertNil(all[0].sessionId)
        XCTAssertEqual(all[0].error, "no such dir")
    }

    /// Only `dispatchId` is required; everything else defaults, so a record from an
    /// older/newer sidecar still decodes.
    func testSparseRecordDecodesWithDefaults() throws {
        try write("""
        [{"dispatchId":"d1"}]
        """)
        let record = readOracleDispatchRegistry().first
        XCTAssertEqual(record?.dispatchId, "d1")
        XCTAssertEqual(record?.outcome, "started")
        XCTAssertEqual(record?.at, 0)
        XCTAssertEqual(record?.provider, "")
    }

    func testGraphInputCarriesWhatTheGraphReads() throws {
        try write("""
        [{"dispatchId":"d1","project":"/p","prompt":"Implement bd ticket juancode-abc",
          "provider":"claude","worktree":true,"telegramChatId":null,"outcome":"started",
          "sessionId":"s1","error":null,"at":99}]
        """)
        let input = readOracleDispatchRegistry().first!.graphInput
        XCTAssertEqual(input, GraphDispatchInput(
            dispatchId: "d1", project: "/p", prompt: "Implement bd ticket juancode-abc",
            provider: "claude", sessionId: "s1", outcome: "started", at: 99))
    }
}
