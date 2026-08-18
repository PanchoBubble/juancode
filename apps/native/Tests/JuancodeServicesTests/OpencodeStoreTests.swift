import Foundation
import JuancodeCore
import Testing

@testable import JuancodeServices

/// Reads against a fixture database built with opencode's own schema (the columns we
/// depend on), so these cover the mapping — not opencode itself.
@Suite struct OpencodeStoreTests {
    /// A throwaway db carrying the `session`/`message`/`part` shape opencode writes.
    private func makeDb() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-fixture-\(UUID().uuidString).db").path
        OpencodeSqlite.exec(path, """
            CREATE TABLE session (
              id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT,
              directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
              time_archived INTEGER, cost REAL DEFAULT 0 NOT NULL,
              tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL,
              tokens_reasoning INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_write INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE TABLE part (
              id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            """)
        return path
    }

    private func insertSession(
        _ db: String, id: String, dir: String, title: String,
        created: Int, updated: Int? = nil, parent: String? = nil, archived: Int? = nil,
        input: Int = 0, output: Int = 0, reasoning: Int = 0,
        cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double = 0
    ) {
        let parentSql = parent.map { "'\($0)'" } ?? "NULL"
        let archivedSql = archived.map(String.init) ?? "NULL"
        OpencodeSqlite.exec(db, """
            INSERT INTO session (id, directory, title, time_created, time_updated, parent_id,
              time_archived, cost, tokens_input, tokens_output, tokens_reasoning,
              tokens_cache_read, tokens_cache_write)
            VALUES ('\(id)', '\(dir)', '\(title)', \(created), \(updated ?? created), \(parentSql),
              \(archivedSql), \(cost), \(input), \(output), \(reasoning), \(cacheRead), \(cacheWrite));
            """)
    }

    @Test func discoversTheNewestSessionCreatedAfterSpawn() {
        let db = makeDb()
        insertSession(db, id: "ses_old", dir: "/repo", title: "older", created: 1_000)
        insertSession(db, id: "ses_new", dir: "/repo", title: "newer", created: 5_500)
        insertSession(db, id: "ses_other", dir: "/elsewhere", title: "wrong cwd", created: 6_000)

        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 5_000, db: db) == "ses_new")
        // Nothing created since a later spawn.
        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 9_000, db: db) == nil)
        // A different folder's session is never adopted.
        #expect(OpencodeStore.scanOnce(cwd: "/nope", sinceMs: 0, db: db) == nil)
    }

    @Test func discoveryAllowsSmallClockSkew() {
        let db = makeDb()
        // Written 1s "before" the spawn timestamp — inside the 2s grace window.
        insertSession(db, id: "ses_skew", dir: "/repo", title: "t", created: 9_000)
        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 10_000, db: db) == "ses_skew")
        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 12_000, db: db) == nil)
    }

    @Test func discoveryIgnoresSubagentSessions() {
        let db = makeDb()
        insertSession(db, id: "ses_child", dir: "/repo", title: "subagent",
                      created: 5_000, parent: "ses_parent")
        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 0, db: db) == nil)
    }

    @Test func titleSkipsOpencodesOwnPlaceholder() {
        let db = makeDb()
        insertSession(db, id: "ses_a", dir: "/repo",
                      title: "New session - 2026-08-18T10:00:00.000Z", created: 1)
        insertSession(db, id: "ses_b", dir: "/repo", title: "Wire up   the paste engine", created: 2)

        #expect(OpencodeStore.title("ses_a", db: db) == nil)
        // Whitespace collapsed by `tidy`, like every other provider's title.
        #expect(OpencodeStore.title("ses_b", db: db) == "Wire up the paste engine")
        #expect(OpencodeStore.title("ses_missing", db: db) == nil)
    }

    @Test func usageReadsTheRunningTotalsAndOpencodesOwnCost() {
        let db = makeDb()
        insertSession(db, id: "ses_u", dir: "/repo", title: "t", created: 1,
                      input: 100, output: 20, reasoning: 5,
                      cacheRead: 900, cacheWrite: 50, cost: 0.42)
        let usage = OpencodeStore.usage("ses_u", db: db)
        #expect(usage?.inputTokens == 100)
        // Reasoning tokens are billed as output, so they're folded into it.
        #expect(usage?.outputTokens == 25)
        #expect(usage?.cacheReadTokens == 900)
        #expect(usage?.cacheWriteTokens == 50)
        #expect(usage?.totalTokens == 1075)
        #expect(usage?.costUsd == 0.42)
    }

    @Test func usageIsNilBeforeTheFirstTurn() {
        let db = makeDb()
        insertSession(db, id: "ses_fresh", dir: "/repo", title: "t", created: 1)
        #expect(OpencodeStore.usage("ses_fresh", db: db) == nil)
    }

    @Test func listsResumableSessionsForAFolderNewestFirst() {
        let db = makeDb()
        insertSession(db, id: "ses_1", dir: "/repo", title: "one", created: 1_000)
        insertSession(db, id: "ses_2", dir: "/repo", title: "two", created: 2_000)
        insertSession(db, id: "ses_sub", dir: "/repo", title: "sub", created: 3_000,
                      parent: "ses_2")
        insertSession(db, id: "ses_gone", dir: "/repo", title: "archived", created: 4_000,
                      archived: 4_500)

        let ids = OpencodeStore.sessions(directory: "/repo", db: db).map(\.id)
        #expect(ids == ["ses_2", "ses_1"])
    }

    @Test func recentSessionsOrdersByLastTouched() {
        let db = makeDb()
        insertSession(db, id: "ses_stale", dir: "/a", title: "stale", created: 1, updated: 10)
        insertSession(db, id: "ses_hot", dir: "/b", title: "hot", created: 2, updated: 99)
        #expect(OpencodeStore.recentSessions(limit: 5, db: db).map(\.id) == ["ses_hot", "ses_stale"])
        #expect(OpencodeStore.recentSessions(limit: 1, db: db).map(\.id) == ["ses_hot"])
    }

    @Test func aMissingDatabaseReadsAsEmptyRatherThanThrowing() {
        let missing = "/tmp/juancode-no-such-opencode-\(UUID().uuidString).db"
        #expect(OpencodeStore.session("ses_x", db: missing) == nil)
        #expect(OpencodeStore.usage("ses_x", db: missing) == nil)
        #expect(OpencodeStore.recentSessions(limit: 5, db: missing).isEmpty)
        #expect(OpencodeStore.scanOnce(cwd: "/repo", sinceMs: 0, db: missing) == nil)
    }

    @Test func dbPathPrefersOurOverride() {
        // Set by the process, so this only asserts the precedence rule holds for
        // whatever the environment says — never mutating it under a parallel test.
        let env = ProcessInfo.processInfo.environment
        if let ours = env["JUANCODE_OPENCODE_DB"], !ours.isEmpty {
            #expect(OpencodeStore.defaultPath == ours)
        } else {
            #expect(OpencodeStore.defaultPath.hasSuffix(".db"))
            #expect(OpencodeStore.defaultPath.contains("opencode"))
        }
    }
}
