import Foundation
import JuancodeCore
import Testing

@testable import JuancodeServices

/// The opencode activity source: part → structured kinds, and the inclusive
/// `time_updated` watermark that lets a tool part's status change count as new
/// activity without re-emitting what was already sent.
@Suite struct OpencodeActivityTailTests {
    private func makeDb() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-tail-\(UUID().uuidString).db").path
        OpencodeSqlite.exec(path, """
            CREATE TABLE session (
              id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER,
              cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL,
              tokens_output INTEGER DEFAULT 0 NOT NULL, tokens_reasoning INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_write INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE TABLE part (
              id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            INSERT INTO message (id, session_id, time_created, time_updated, data)
              VALUES ('msg_u', 'ses_1', 1, 1, '{"role":"user"}'),
                     ('msg_a', 'ses_1', 2, 2, '{"role":"assistant"}');
            """)
        return path
    }

    /// `data` is inlined into the SQL, so keep the JSON free of single quotes.
    private func insertPart(_ db: String, id: String, message: String, updated: Int, data: String) {
        OpencodeSqlite.exec(db, """
            INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
            VALUES ('\(id)', '\(message)', 'ses_1', \(updated), \(updated), '\(data)');
            """)
    }

    private func updatePart(_ db: String, id: String, updated: Int, data: String) {
        OpencodeSqlite.exec(db, """
            UPDATE part SET time_updated = \(updated), data = '\(data)' WHERE id = '\(id)';
            """)
    }

    private func row(_ type: String, role: String, data: [String: Any]) -> OpencodeStore.PartRow {
        OpencodeStore.PartRow(id: "prt", updatedMs: 0, data: data, role: role)
    }

    // MARK: - part mapping

    @Test func userAndAssistantTextMapByTheirMessageRole() {
        let user = opencodePartBatch(row("text", role: "user", data: ["type": "text", "text": "hi"]))
        #expect(user.batch.kinds == [.user])

        let agent = opencodePartBatch(
            row("text", role: "assistant", data: ["type": "text", "text": "on it"]))
        #expect(agent.batch.kinds == [.assistant])
        // The role is part of the signature, so a re-read at a new role is new activity.
        #expect(user.signature != agent.signature)
    }

    @Test func blankTextAndUnknownPartsCarryNoActivity() {
        #expect(opencodePartBatch(
            row("text", role: "assistant", data: ["type": "text", "text": "   "])).batch.kinds == [])
        #expect(opencodePartBatch(
            row("step-start", role: "assistant", data: ["type": "step-start"])).batch.kinds == [])
        #expect(opencodePartBatch(
            row("reasoning", role: "assistant", data: ["type": "reasoning", "text": ""]))
            .batch.kinds == [])
    }

    @Test func reasoningIsThinking() {
        let events = opencodePartBatch(
            row("reasoning", role: "assistant", data: ["type": "reasoning", "text": "weighing it"]))
        #expect(events.batch.kinds == [.thinking])
    }

    @Test func aToolPartOpensWhileRunningAndResolvesWhenDone() {
        let running = opencodePartBatch(row("tool", role: "assistant", data: [
            "type": "tool", "callID": "call_1", "state": ["status": "running"],
        ]))
        #expect(running.batch.kinds == [.toolUse])
        #expect(running.batch.openedToolUseIds == ["call_1"])

        let done = opencodePartBatch(row("tool", role: "assistant", data: [
            "type": "tool", "callID": "call_1", "state": ["status": "completed"],
        ]))
        #expect(done.batch.kinds == [.toolResult])
        #expect(done.batch.resolvedToolUseIds == ["call_1"])
        // A failed tool still resolves — the detector must not hold busy forever.
        let failed = opencodePartBatch(row("tool", role: "assistant", data: [
            "type": "tool", "callID": "call_1", "state": ["status": "error"],
        ]))
        #expect(failed.batch.kinds == [.toolResult])
        #expect(running.signature != done.signature)
    }

    // MARK: - the tail

    /// Collects the batches a tail emits, so a test can poll it by hand.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [(StructuredEventBatch, Bool)] = []
        var listener: @Sendable (StructuredEventBatch, Bool) -> Void {
            { [self] batch, reset in lock.withLock { batches.append((batch, reset)) } }
        }
        var all: [(StructuredEventBatch, Bool)] { lock.withLock { batches } }
    }

    @Test func theFirstPollSkipsTheBacklogAndReportsAReset() {
        let db = makeDb()
        insertPart(db, id: "prt_old", message: "msg_a", updated: 100,
                   data: #"{"type":"text","text":"history"}"#)
        let sink = Sink()
        let tail = OpencodeActivityTail(cliSessionId: { "ses_1" }, db: db, listener: sink.listener)

        tail.poll()
        #expect(sink.all.count == 1)
        #expect(sink.all[0].1 == true)          // reset
        #expect(sink.all[0].0.kinds.isEmpty)    // a resumed conversation doesn't pulse busy
        // Nothing new since: no further emission.
        tail.poll()
        #expect(sink.all.count == 1)
    }

    @Test func newPartsEmitOnceAndAToolStatusChangeEmitsAgain() {
        let db = makeDb()
        insertPart(db, id: "prt_0", message: "msg_a", updated: 100,
                   data: #"{"type":"text","text":"history"}"#)
        let sink = Sink()
        let tail = OpencodeActivityTail(cliSessionId: { "ses_1" }, db: db, listener: sink.listener)
        tail.poll()  // watermark = 100

        insertPart(db, id: "prt_1", message: "msg_a", updated: 200,
                   data: #"{"type":"tool","callID":"call_9","state":{"status":"running"}}"#)
        tail.poll()
        #expect(sink.all.count == 2)
        #expect(sink.all[1].0.kinds == [.toolUse])
        #expect(sink.all[1].0.openedToolUseIds == ["call_9"])
        #expect(sink.all[1].1 == false)

        // Re-polling with nothing changed must not re-emit the row at the watermark.
        tail.poll()
        #expect(sink.all.count == 2)

        // The same row rewritten as completed: new state, so new activity.
        updatePart(db, id: "prt_1", updated: 300,
                   data: #"{"type":"tool","callID":"call_9","state":{"status":"completed"}}"#)
        tail.poll()
        #expect(sink.all.count == 3)
        #expect(sink.all[2].0.kinds == [.toolResult])
        #expect(sink.all[2].0.resolvedToolUseIds == ["call_9"])
    }

    @Test func twoPartsWrittenInTheSameMillisecondBothEmitExactlyOnce() {
        let db = makeDb()
        let sink = Sink()
        let tail = OpencodeActivityTail(cliSessionId: { "ses_1" }, db: db, listener: sink.listener)
        tail.poll()  // empty session: watermark = 0

        insertPart(db, id: "prt_a", message: "msg_a", updated: 500,
                   data: #"{"type":"text","text":"first"}"#)
        tail.poll()
        insertPart(db, id: "prt_b", message: "msg_a", updated: 500,
                   data: #"{"type":"text","text":"second"}"#)
        tail.poll()

        let emitted = sink.all.dropFirst().flatMap(\.0.kinds)
        #expect(emitted == [.assistant, .assistant])
    }

    @Test func nothingIsEmittedUntilTheSessionIdIsDiscovered() {
        let db = makeDb()
        let sink = Sink()
        let tail = OpencodeActivityTail(cliSessionId: { nil }, db: db, listener: sink.listener)
        tail.poll()
        #expect(sink.all.isEmpty)
    }
}
