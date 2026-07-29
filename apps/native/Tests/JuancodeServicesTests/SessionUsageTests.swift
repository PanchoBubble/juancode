import XCTest
@testable import JuancodeServices

final class SessionUsageTests: XCTestCase {
    /// One temp root for the whole suite, removed afterwards (mirrors the TS
    /// `mkdtempSync` + `afterAll(rmSync)`).
    private static let tmp: String = {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-usage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func jsonl(_ records: [Any]) -> String {
        records.map { rec in
            let data = try! JSONSerialization.data(
                withJSONObject: rec, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
    }

    private func write(_ path: String, _ contents: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Append records the way a CLI does — in place, so the incremental reader's
    /// remembered offset stays meaningful (juancode-dfhg).
    private func appendRecords(_ path: String, _ records: [Any]) {
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try! handle.write(contentsOf: Data(jsonl(records).utf8))
    }

    private func claudeTranscript(_ root: String, _ id: String) -> String {
        let dir = (root as NSString).appendingPathComponent("-Users-someone-project")
        return (dir as NSString).appendingPathComponent("\(id).jsonl")
    }

    private func claudeFixture(_ id: String, _ records: [Any]) -> String {
        let root = (Self.tmp as NSString).appendingPathComponent("claude-\(id)")
        let dir = (root as NSString).appendingPathComponent("-Users-someone-project")
        write((dir as NSString).appendingPathComponent("\(id).jsonl"), jsonl(records))
        return root
    }

    private func codexFixture(
        _ id: String, _ records: [Any], _ name: String = "rollout-x.jsonl"
    ) -> String {
        let root = (Self.tmp as NSString).appendingPathComponent("codex-\(id)")
        let dir = ((root as NSString).appendingPathComponent("2026/06") as NSString)
            .appendingPathComponent("23")
        write((dir as NSString).appendingPathComponent(name), jsonl(records))
        return root
    }

    private func assistant(
        _ msgId: String,
        _ requestId: String,
        _ usage: [String: Int],
        _ model: String = "claude-opus-4-8"
    ) -> [String: Any] {
        [
            "type": "assistant",
            "requestId": requestId,
            "message": ["id": msgId, "model": model, "usage": usage],
        ]
    }

    // MARK: - deriveClaudeUsage

    func testSumsTokensAcrossTurnsAndEstimatesOpusCost() async {
        let id = "11111111-1111-1111-1111-111111111111"
        let root = claudeFixture(id, [
            ["type": "user", "message": "hi"],
            assistant("m1", "r1", [
                "input_tokens": 1000,
                "output_tokens": 200,
                "cache_read_input_tokens": 5000,
                "cache_creation_input_tokens": 800,
            ]),
            assistant("m2", "r2", ["input_tokens": 10, "output_tokens": 400]),
        ])
        let u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 1010)
        XCTAssertEqual(u.outputTokens, 600)
        XCTAssertEqual(u.cacheReadTokens, 5000)
        XCTAssertEqual(u.cacheWriteTokens, 800)
        XCTAssertEqual(u.totalTokens, 1010 + 600 + 5000 + 800)
        // opus: $5/MTok in, $25/MTok out, cache read 0.1x, cache write 1.25x.
        // (1010*5 + 5000*0.5 + 800*6.25 + 600*25) / 1e6
        let inCost: Double = 1010.0 * 5
        let cacheReadCost: Double = 5000.0 * 0.5
        let cacheWriteCost: Double = 800.0 * 6.25
        let outCost: Double = 600.0 * 25
        let expected: Double = (inCost + cacheReadCost + cacheWriteCost + outCost) / 1_000_000
        XCTAssertEqual(u.costUsd!, expected, accuracy: 1e-9)
    }

    func testDedupsTurnsLoggedTwice() async {
        let id = "22222222-2222-2222-2222-222222222222"
        let dup = assistant("m1", "r1", ["input_tokens": 100, "output_tokens": 50])
        let root = claudeFixture(id, [dup, dup, dup])
        let u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 100)
        XCTAssertEqual(u.outputTokens, 50)
    }

    func testIgnoresSyntheticMessages() async {
        let id = "33333333-3333-3333-3333-333333333333"
        let root = claudeFixture(id, [
            assistant("m1", "r1", ["input_tokens": 999, "output_tokens": 999], "<synthetic>"),
            assistant("m2", "r2", ["input_tokens": 10, "output_tokens": 20]),
        ])
        let u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 10)
        XCTAssertEqual(u.outputTokens, 20)
    }

    func testReturnsNullCostForUnknownModelButCountsTokens() async {
        let id = "44444444-4444-4444-4444-444444444444"
        let root = claudeFixture(id, [
            assistant("m1", "r1", ["input_tokens": 10, "output_tokens": 20], "some-future-model"),
        ])
        let u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.totalTokens, 30)
        XCTAssertNil(u.costUsd)
    }

    func testReturnsNullBeforeAnyAssistantTurn() async {
        let id = "55555555-5555-5555-5555-555555555555"
        let root = claudeFixture(id, [["type": "user", "message": "hi"]])
        let u = await deriveClaudeUsage(id, root)
        XCTAssertNil(u)
    }

    func testReturnsNullWhenTranscriptMissing() async {
        let root = claudeFixture(
            "present", [assistant("m", "r", ["input_tokens": 1, "output_tokens": 1])])
        let u = await deriveClaudeUsage("nope-missing", root)
        XCTAssertNil(u)
    }

    // MARK: - incremental polling (juancode-dfhg)

    /// Each poll folds only the newly appended turns into the running total, and a
    /// turn logged again in a later pass is still deduped.
    func testAccumulatesAppendedTurnsAcrossPollsWithoutDoubleCounting() async {
        let id = "88888888-8888-8888-8888-888888888888"
        let first = assistant("m1", "r1", ["input_tokens": 100, "output_tokens": 50])
        let root = claudeFixture(id, [first])
        let file = claudeTranscript(root, id)

        var u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 100)
        XCTAssertEqual(u.outputTokens, 50)

        appendRecords(file, [assistant("m2", "r2", ["input_tokens": 7, "output_tokens": 3])])
        u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 107, "the earlier turn's tokens must survive the next poll")
        XCTAssertEqual(u.outputTokens, 53)

        // The same response logged a second time, one poll later.
        appendRecords(file, [first])
        u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 107, "a duplicate in a later pass must not be counted")
        XCTAssertEqual(u.outputTokens, 53)

        // Nothing appended: the totals hold.
        u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.totalTokens, 160)
    }

    /// A turn appended after a poll that found nothing still flips usage from nil.
    func testFirstTurnAppendedAfterAnEmptyPollIsPickedUp() async {
        let id = "99999999-9999-9999-9999-999999999999"
        let root = claudeFixture(id, [["type": "user", "message": "hi"]])
        let beforeAnyTurn = await deriveClaudeUsage(id, root)
        XCTAssertNil(beforeAnyTurn)

        appendRecords(claudeTranscript(root, id),
                      [assistant("m1", "r1", ["input_tokens": 4, "output_tokens": 6])])
        let u = (await deriveClaudeUsage(id, root))!
        XCTAssertEqual(u.totalTokens, 10)
    }

    // MARK: - deriveCodexUsage

    private func tokenCount(_ info: [String: Int]) -> [String: Any] {
        [
            "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": info]],
        ]
    }

    func testTakesLastCumulativeTokenCountAndReportsNoCost() async {
        let id = "66666666-6666-6666-6666-666666666666"
        let root = codexFixture(id, [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/x"]],
            tokenCount(["input_tokens": 100, "cached_input_tokens": 0,
                        "output_tokens": 10, "total_tokens": 110]),
            tokenCount(["input_tokens": 5000, "cached_input_tokens": 4000,
                        "output_tokens": 600, "total_tokens": 5600]),
        ])
        let u = (await deriveCodexUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 1000)  // 5000 - 4000 cached
        XCTAssertEqual(u.cacheReadTokens, 4000)
        XCTAssertEqual(u.outputTokens, 600)
        XCTAssertEqual(u.totalTokens, 5600)
        XCTAssertNil(u.costUsd)
    }

    func testReturnsNullWhenMatchingSessionHasNoTokenCount() async {
        let id = "77777777-7777-7777-7777-777777777777"
        let root = codexFixture(id, [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/x"]],
        ])
        let u = await deriveCodexUsage(id, root)
        XCTAssertNil(u)
    }

    /// Codex reports a cumulative tally, so a later poll's newest `token_count` wins
    /// and a poll with nothing appended keeps the last one.
    func testCodexKeepsTheNewestCumulativeTallyAcrossPolls() async {
        let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let root = codexFixture(id, [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/x"]],
            tokenCount(["input_tokens": 100, "cached_input_tokens": 0,
                        "output_tokens": 10, "total_tokens": 110]),
        ])
        let file = (((root as NSString).appendingPathComponent("2026/06") as NSString)
            .appendingPathComponent("23") as NSString).appendingPathComponent("rollout-x.jsonl")

        var u = (await deriveCodexUsage(id, root))!
        XCTAssertEqual(u.totalTokens, 110)

        appendRecords(file, [tokenCount(["input_tokens": 5000, "cached_input_tokens": 4000,
                                         "output_tokens": 600, "total_tokens": 5600])])
        u = (await deriveCodexUsage(id, root))!
        XCTAssertEqual(u.inputTokens, 1000)
        XCTAssertEqual(u.cacheReadTokens, 4000)
        XCTAssertEqual(u.totalTokens, 5600)

        u = (await deriveCodexUsage(id, root))!
        XCTAssertEqual(u.totalTokens, 5600, "a poll with nothing new keeps the last tally")
    }

    func testIgnoresRolloutsForOtherSessions() async {
        let root = codexFixture("other", [
            ["type": "session_meta", "payload": ["id": "other", "cwd": "/x"]],
            tokenCount(["input_tokens": 1, "cached_input_tokens": 0,
                        "output_tokens": 1, "total_tokens": 2]),
        ])
        let u = await deriveCodexUsage("not-me", root)
        XCTAssertNil(u)
    }
}
