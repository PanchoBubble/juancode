import XCTest
@testable import JuancodeCore
@testable import JuancodeServices

/// Mirrors apps/server/src/structuredTranscript.test.ts, adapted to the
/// activity-only (kinds, no rich events) native tail.
final class StructuredTranscriptTests: XCTestCase {
    private static let tmp: String = {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-structured-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func jsonl(_ records: [Any]) -> String {
        records.map { rec in
            let data = try! JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
    }

    private func write(_ path: String, _ contents: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func append(_ path: String, _ contents: String) {
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(contents.data(using: .utf8)!)
    }

    /// Write a Claude transcript and return (root, file).
    private func claudeFixture(_ id: String, _ records: [Any]) -> (root: String, file: String) {
        let root = (Self.tmp as NSString).appendingPathComponent("claude-\(id)")
        let dir = (root as NSString).appendingPathComponent("-Users-someone-project")
        let file = (dir as NSString).appendingPathComponent("\(id).jsonl")
        write(file, jsonl(records))
        return (root, file)
    }

    private func codexFixture(_ id: String, _ records: [Any]) -> (root: String, file: String) {
        let root = (Self.tmp as NSString).appendingPathComponent("codex-\(id)")
        let dir = (root as NSString).appendingPathComponent("2026/06/23")
        let file = (dir as NSString).appendingPathComponent("rollout-test.jsonl")
        write(file, jsonl([["type": "session_meta", "payload": ["id": id]]] + records))
        return (root, file)
    }

    /// Thread-safe batch collector for the @Sendable listener.
    private final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(batch: StructuredEventBatch, reset: Bool)] = []
        func add(_ batch: StructuredEventBatch, _ reset: Bool) { lock.withLock { items.append((batch, reset)) } }
        var all: [(batch: StructuredEventBatch, reset: Bool)] { lock.withLock { items } }
    }

    // MARK: - resolveTranscriptFile

    func testResolvesClaudeByBasename() async {
        let (root, file) = claudeFixture("sess-a", [["type": "user", "message": ["content": "hi"]]])
        let roots = TitleRoots(claudeProjects: root)
        let resolved = await resolveTranscriptFile(.claude, "sess-a", roots)
        XCTAssertEqual(resolved, file)
        let missing = await resolveTranscriptFile(.claude, "missing", roots)
        XCTAssertNil(missing)
    }

    func testResolvesCodexBySessionMetaId() async {
        let (root, file) = codexFixture("sess-c", [["payload": ["type": "agent_message", "message": "yo"]]])
        let roots = TitleRoots(codexSessions: root)
        let resolved = await resolveTranscriptFile(.codex, "sess-c", roots)
        XCTAssertEqual(resolved, file)
        let missing = await resolveTranscriptFile(.codex, "nope", roots)
        XCTAssertNil(missing)
    }

    // MARK: - TranscriptActivityTail

    func testEmitsBacklogResetThenAppendedKinds() async {
        let (root, file) = claudeFixture("tail-1", [
            ["type": "user", "message": ["role": "user", "content": "first"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "hello"]]]],
        ])
        let batches = Batches()
        let tail = TranscriptActivityTail(
            provider: .claude,
            cliSessionId: { "tail-1" },
            roots: TitleRoots(claudeProjects: root)
        ) { batch, reset in batches.add(batch, reset) }

        await tail.poll()
        XCTAssertEqual(batches.all.count, 1)
        XCTAssertTrue(batches.all[0].reset)
        XCTAssertEqual(batches.all[0].batch.kinds, [.user, .assistant])

        // A poll with no new bytes emits nothing further.
        await tail.poll()
        XCTAssertEqual(batches.all.count, 1)

        // Append a new turn; the next poll emits just the new kind, reset:false.
        append(file, jsonl([
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "more"]]]],
        ]))
        await tail.poll()
        XCTAssertEqual(batches.all.count, 2)
        XCTAssertFalse(batches.all[1].reset)
        XCTAssertEqual(batches.all[1].batch.kinds, [.assistant])
    }

    func testCarriesClaudeToolUseIdsThroughTheTail() async {
        let (root, file) = claudeFixture("tail-tools", [
            ["type": "user", "message": ["role": "user", "content": "go"]],
        ])
        let batches = Batches()
        let tail = TranscriptActivityTail(
            provider: .claude,
            cliSessionId: { "tail-tools" },
            roots: TitleRoots(claudeProjects: root)
        ) { batch, reset in batches.add(batch, reset) }
        await tail.poll() // swallow the backlog

        append(file, jsonl([
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_1", "name": "Task", "input": [:]],
            ]]],
        ]))
        await tail.poll()
        XCTAssertEqual(batches.all[1].batch.kinds, [.toolUse])
        XCTAssertEqual(batches.all[1].batch.openedToolUseIds, ["toolu_1"])
        XCTAssertEqual(batches.all[1].batch.resolvedToolUseIds, [])

        append(file, jsonl([
            ["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"],
            ]]],
        ]))
        await tail.poll()
        XCTAssertEqual(batches.all[2].batch.kinds, [.toolResult])
        XCTAssertEqual(batches.all[2].batch.openedToolUseIds, [])
        XCTAssertEqual(batches.all[2].batch.resolvedToolUseIds, ["toolu_1"])
    }

    func testStaysQuietWhileTranscriptUnresolved() async {
        let batches = Batches()
        let tail = TranscriptActivityTail(
            provider: .claude,
            cliSessionId: { "tail-missing" },
            roots: TitleRoots(claudeProjects: (Self.tmp as NSString).appendingPathComponent("claude-tail-1"))
        ) { batch, reset in batches.add(batch, reset) }
        await tail.poll()
        XCTAssertEqual(batches.all.count, 0)
    }

    func testRereadsLazilyResolvedGetterId() async {
        let (root, _) = claudeFixture("tail-late", [
            ["type": "user", "message": ["role": "user", "content": "late"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "hi"]]]],
        ])
        // id not known when the tail first polls.
        final class Box: @unchecked Sendable { let l = NSLock(); var v: String?
            var value: String? { get { l.withLock { v } } set { l.withLock { v = newValue } } } }
        let box = Box()
        let batches = Batches()
        let tail = TranscriptActivityTail(
            provider: .claude,
            cliSessionId: { box.value },
            roots: TitleRoots(claudeProjects: root)
        ) { batch, reset in batches.add(batch, reset) }

        await tail.poll() // id still nil — nothing emitted yet
        XCTAssertEqual(batches.all.count, 0)

        box.value = "tail-late" // discovered after spawn
        await tail.poll()
        XCTAssertEqual(batches.all.count, 1)
        XCTAssertEqual(batches.all[0].batch.kinds, [.user, .assistant])
    }

    func testCodexKindMapping() async {
        let (root, _) = codexFixture("tail-codex", [
            ["payload": ["type": "user_message", "message": "go"]],
            ["payload": ["type": "function_call", "name": "shell", "arguments": "{}", "call_id": "call_1"]],
            ["payload": ["type": "function_call_output", "output": "ok", "call_id": "call_1"]],
            ["payload": ["type": "agent_message", "message": "done"]],
        ])
        let batches = Batches()
        let tail = TranscriptActivityTail(
            provider: .codex,
            cliSessionId: { "tail-codex" },
            roots: TitleRoots(codexSessions: root)
        ) { batch, reset in batches.add(batch, reset) }
        await tail.poll()
        XCTAssertEqual(batches.all[0].batch.kinds, [.user, .toolUse, .toolResult, .assistant])
        XCTAssertEqual(batches.all[0].batch.openedToolUseIds, ["call_1"])
        XCTAssertEqual(batches.all[0].batch.resolvedToolUseIds, ["call_1"])
    }
}
