import XCTest
@testable import JuancodeServices

final class SessionTitleTests: XCTestCase {
    /// One temp root for the whole suite, removed afterwards (mirrors the TS
    /// `mkdtempSync` + `afterAll(rmSync)`).
    private static let tmp: String = {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-title-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    /// Serialize `records` as one JSON object per line, trailing newline (matches
    /// the TS `jsonl` helper).
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

    /// Write a Claude transcript under <root>/<encoded-cwd>/<id>.jsonl and return root.
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

    // MARK: - tidy

    func testTidyCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(tidy("  fix   the\n\tbug "), "fix the bug")
    }

    func testTidyReturnsNullForBlankInput() {
        XCTAssertNil(tidy("   \n  "))
    }

    func testTidyTruncatesWithEllipsisPastMax() {
        let out = tidy(String(repeating: "x", count: 200))!
        XCTAssertEqual(out.count, 80)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    // MARK: - deriveClaudeTitle

    func testReturnsLatestAiTitle() async {
        let id = "11111111-1111-1111-1111-111111111111"
        let root = claudeFixture(id, [
            ["type": "user", "message": "hi"],
            ["type": "ai-title", "aiTitle": "First guess", "sessionId": id],
            ["type": "assistant", "message": "..."],
            ["type": "ai-title", "aiTitle": "Fix the auth redirect bug", "sessionId": id],
        ])
        let title = await deriveClaudeTitle(id, root)
        XCTAssertEqual(title, "Fix the auth redirect bug")
    }

    func testReturnsNullWhenNoAiTitleYet() async {
        let id = "22222222-2222-2222-2222-222222222222"
        let root = claudeFixture(id, [["type": "user", "message": "hi"]])
        let title = await deriveClaudeTitle(id, root)
        XCTAssertNil(title)
    }

    func testReturnsNullWhenTranscriptMissing() async {
        let root = claudeFixture("present", [["type": "ai-title", "aiTitle": "x"]])
        let title = await deriveClaudeTitle("33333333-missing", root)
        XCTAssertNil(title)
    }

    // MARK: - incremental polling (juancode-dfhg)

    /// Successive polls read only what was appended: a newer `ai-title` replaces the
    /// old one, and a poll that brought nothing new keeps the title already found
    /// (rather than falling back to the placeholder).
    func testKeepsAndUpdatesTheTitleAcrossPolls() async {
        let id = "77777777-7777-7777-7777-777777777777"
        let root = claudeFixture(id, [["type": "user", "message": "hi"]])
        let file = ((root as NSString).appendingPathComponent("-Users-someone-project") as NSString)
            .appendingPathComponent("\(id).jsonl")
        let beforeAnyTitle = await deriveClaudeTitle(id, root)
        XCTAssertNil(beforeAnyTitle)

        appendRecords(file, [["type": "ai-title", "aiTitle": "First guess", "sessionId": id]])
        var title = await deriveClaudeTitle(id, root)
        XCTAssertEqual(title, "First guess")

        // Nothing appended: the title an earlier pass found still stands.
        title = await deriveClaudeTitle(id, root)
        XCTAssertEqual(title, "First guess")

        appendRecords(file, [["type": "ai-title", "aiTitle": "Fix the auth redirect bug",
                              "sessionId": id]])
        title = await deriveClaudeTitle(id, root)
        XCTAssertEqual(title, "Fix the auth redirect bug")
    }

    /// Append records the way a CLI does — in place, so the incremental reader's
    /// remembered offset stays meaningful.
    private func appendRecords(_ path: String, _ records: [Any]) {
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try! handle.write(contentsOf: Data(jsonl(records).utf8))
    }

    // MARK: - deriveCodexTitle

    func testReturnsFirstUserMessageForMatchingSession() async {
        let id = "44444444-4444-4444-4444-444444444444"
        let root = codexFixture(id, [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/x"]],
            ["type": "response_item",
             "payload": ["type": "message", "role": "user", "content": "AGENTS.md…"]],
            ["type": "event_msg",
             "payload": ["type": "user_message", "message": "Add a dark mode toggle"]],
            ["type": "event_msg",
             "payload": ["type": "user_message", "message": "second prompt"]],
        ])
        let title = await deriveCodexTitle(id, root)
        XCTAssertEqual(title, "Add a dark mode toggle")
    }

    func testReturnsNullWhenMatchingSessionHasNoPrompt() async {
        let id = "55555555-5555-5555-5555-555555555555"
        let root = codexFixture(id, [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/x"]],
        ])
        let title = await deriveCodexTitle(id, root)
        XCTAssertNil(title)
    }

    func testIgnoresRolloutsBelongingToOtherSessions() async {
        let root = codexFixture("other", [
            ["type": "session_meta", "payload": ["id": "other", "cwd": "/x"]],
            ["type": "event_msg",
             "payload": ["type": "user_message", "message": "not mine"]],
        ])
        let title = await deriveCodexTitle("66666666-nope", root)
        XCTAssertNil(title)
    }
}
