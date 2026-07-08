import Foundation
import GRDB
import JuancodeCore

/// SQLite-backed `PersistentStore` (juancode-u34.5), a faithful port of
/// `apps/server/src/db.ts` onto GRDB. Persists session metadata + capped
/// scrollback, GitHub-PR-style inline diff comments, cached 'Review with Claude'
/// results, and an FTS5 full-text index over session titles + scrollback so
/// history (and search) survive app restarts.
///
/// Schema-compatible with the Node `juancode.db`: scrollback is stored as TEXT
/// (a lossy UTF-8 decode of the raw pty bytes) so the same data dir is readable
/// by either implementation. Replay fidelity is preserved end to end because the
/// trim happens on byte boundaries upstream (see `Scrollback`).
public final class GRDBStore: PersistentStore, MessageQueuePersistence, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    /// Open (creating if needed) the database at `path`. Defaults to
    /// `<Config.dataDir>/juancode.db`, mirroring the Node server's location.
    public init(path: String? = nil) throws {
        let dbPath = path ?? Self.defaultPath()
        try FileManager.default.createDirectory(
            atPath: (dbPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var config = Configuration()
        // Match better-sqlite3's `journal_mode = WAL`.
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try migrate()
    }

    /// An ephemeral in-memory database — the degraded fallback when the on-disk
    /// store can't be opened (corrupt / locked / unwritable data dir). The app
    /// still runs this launch on it, though nothing persists; the UI surfaces a
    /// recovery banner offering to reset the on-disk file (juancode-4zk).
    public init(inMemory: Bool) throws {
        precondition(inMemory, "use init(path:) for an on-disk store")
        dbQueue = try DatabaseQueue() // no path ⇒ in-memory
        try migrate()
    }

    public static func defaultPath() -> String {
        (Config.dataDir as NSString).appendingPathComponent("juancode.db")
    }

    // MARK: - schema + migrations

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id               TEXT PRIMARY KEY,
                    provider         TEXT NOT NULL,
                    cwd              TEXT NOT NULL,
                    title            TEXT NOT NULL,
                    status           TEXT NOT NULL,
                    exit_code        INTEGER,
                    cli_session_id   TEXT,
                    scrollback       TEXT NOT NULL DEFAULT '',
                    skip_permissions INTEGER NOT NULL DEFAULT 0,
                    worktree_path    TEXT,
                    usage            TEXT,
                    archived         INTEGER NOT NULL DEFAULT 0,
                    dormant          INTEGER NOT NULL DEFAULT 0,
                    created_at       INTEGER NOT NULL,
                    updated_at       INTEGER NOT NULL
                );
                """)

            // Forward-compatible migrations for an existing (Node-created) db that
            // predates a column, mirroring db.ts.
            let cols = try Set(Row.fetchAll(db, sql: "PRAGMA table_info(sessions)").map { $0["name"] as String })
            if !cols.contains("cli_session_id") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN cli_session_id TEXT")
            }
            if !cols.contains("skip_permissions") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN skip_permissions INTEGER NOT NULL DEFAULT 0")
            }
            if !cols.contains("worktree_path") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN worktree_path TEXT")
            }
            if !cols.contains("usage") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN usage TEXT")
            }
            if !cols.contains("archived") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
            }
            if !cols.contains("dormant") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN dormant INTEGER NOT NULL DEFAULT 0")
            }

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS diff_comments (
                    id          TEXT PRIMARY KEY,
                    session_id  TEXT NOT NULL,
                    file        TEXT NOT NULL,
                    side        TEXT NOT NULL,
                    line        INTEGER NOT NULL,
                    end_line    INTEGER NOT NULL,
                    body        TEXT NOT NULL,
                    created_at  INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_diff_comments_session ON diff_comments(session_id);
                """)

            let commentCols = try Set(Row.fetchAll(db, sql: "PRAGMA table_info(diff_comments)").map { $0["name"] as String })
            if !commentCols.contains("end_line") {
                try db.execute(sql: "ALTER TABLE diff_comments ADD COLUMN end_line INTEGER NOT NULL DEFAULT 0")
                try db.execute(sql: "UPDATE diff_comments SET end_line = line WHERE end_line = 0")
            }

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS diff_reviews (
                    session_id  TEXT PRIMARY KEY,
                    payload     TEXT NOT NULL,
                    created_at  INTEGER NOT NULL
                );
                """)

            // Per-session outbound message queue (oracle-cj3 / juancode-r82):
            // instructions lined up while the agent was busy, delivered in order on
            // the next idle. Persisted so the queue survives a reconnect / restart
            // and a session reactivating. Insertion order (and thus delivery order)
            // is the implicit `rowid`. Mirrors `message_queue` in db.ts.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_queue (
                    id          TEXT PRIMARY KEY,
                    session_id  TEXT NOT NULL,
                    text        TEXT NOT NULL,
                    created_at  INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_message_queue_session ON message_queue(session_id);
                """)

            // Contentless FTS5 mirror of sessions(title, scrollback), keyed by id.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                    session_id UNINDEXED,
                    title,
                    scrollback
                );
                """)

            // Backfill the FTS index the first time it's empty (older db / rebuild).
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts") ?? 0
            if ftsCount == 0 {
                try db.execute(sql: """
                    INSERT INTO sessions_fts (session_id, title, scrollback)
                    SELECT id, title, scrollback FROM sessions
                    """)
            }
        }
    }

    // MARK: - row mapping

    private func rowToMeta(_ r: Row) -> SessionMeta {
        SessionMeta(
            id: r["id"],
            provider: ProviderId(rawValue: r["provider"]) ?? .claude,
            cwd: r["cwd"],
            title: r["title"],
            status: (r["status"] as String) == "running" ? .running : .exited,
            exitCode: r["exit_code"],
            createdAt: r["created_at"],
            updatedAt: r["updated_at"],
            cliSessionId: r["cli_session_id"],
            skipPermissions: (r["skip_permissions"] as Int) == 1,
            worktreePath: r["worktree_path"],
            usage: Self.decodeUsage(r["usage"]),
            archived: (r["archived"] as Int? ?? 0) == 1,
            dormant: (r["dormant"] as Int? ?? 0) == 1
        )
    }

    private static func decodeUsage(_ raw: String?) -> SessionUsage? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionUsage.self, from: data)
    }

    private static func encodeUsage(_ usage: SessionUsage?) -> String? {
        guard let usage, let data = try? JSONEncoder().encode(usage) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lossy UTF-8 view of raw scrollback bytes, for the TEXT column + FTS.
    private static func scrollbackText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // FTS is contentless, so a row "update" is delete-then-insert.
    private func syncFts(_ db: Database, id: String, title: String, scrollback: String) throws {
        try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?", arguments: [id])
        try db.execute(
            sql: "INSERT INTO sessions_fts (session_id, title, scrollback) VALUES (?, ?, ?)",
            arguments: [id, title, scrollback]
        )
    }

    // MARK: - SessionStore (write-path)

    public func insert(_ meta: SessionMeta) {
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, provider, cwd, title, status, exit_code, cli_session_id,
                                      scrollback, skip_permissions, worktree_path, usage, archived, dormant, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    meta.id, meta.provider.rawValue, meta.cwd, meta.title, meta.status.rawValue,
                    meta.exitCode, meta.cliSessionId, meta.skipPermissions ? 1 : 0,
                    meta.worktreePath, Self.encodeUsage(meta.usage), meta.archived ? 1 : 0,
                    meta.dormant ? 1 : 0, meta.createdAt, meta.updatedAt,
                ])
            try syncFts(db, id: meta.id, title: meta.title, scrollback: "")
        }
    }

    public func update(_ meta: SessionMeta, scrollback: [UInt8]) {
        let text = Self.scrollbackText(scrollback)
        try? dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sessions
                SET title = ?, status = ?, exit_code = ?, cli_session_id = ?, scrollback = ?,
                    skip_permissions = ?, worktree_path = ?, usage = ?, archived = ?, dormant = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    meta.title, meta.status.rawValue, meta.exitCode, meta.cliSessionId, text,
                    meta.skipPermissions ? 1 : 0, meta.worktreePath, Self.encodeUsage(meta.usage),
                    meta.archived ? 1 : 0, meta.dormant ? 1 : 0, meta.updatedAt, meta.id,
                ])
            try syncFts(db, id: meta.id, title: meta.title, scrollback: text)
        }
    }

    public func setCliSessionId(_ id: String, cliSessionId: String) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET cli_session_id = ? WHERE id = ?",
                arguments: [cliSessionId, id]
            )
        }
    }

    public func setTitle(_ id: String, title: String) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, nowMs(), id]
            )
            // Keep the FTS title in sync without touching the stored scrollback.
            let scroll = try String.fetchOne(
                db, sql: "SELECT scrollback FROM sessions WHERE id = ?", arguments: [id]) ?? ""
            try syncFts(db, id: id, title: title, scrollback: scroll)
        }
    }

    public func setArchived(_ id: String, archived: Bool) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET archived = ?, updated_at = ? WHERE id = ?",
                arguments: [archived ? 1 : 0, nowMs(), id]
            )
        }
    }

    public func getScrollback(_ id: String) -> [UInt8]? {
        try? dbQueue.read { db -> [UInt8]? in
            guard let text = try String.fetchOne(db, sql: "SELECT scrollback FROM sessions WHERE id = ?", arguments: [id])
            else { return nil }
            return Array(text.utf8)
        } ?? nil
    }

    // MARK: - PersistentStore: read / admin

    public func get(_ id: String) -> SessionMeta? {
        try? dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id]).map(rowToMeta)
        } ?? nil
    }

    public func list() -> [SessionMeta] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions ORDER BY created_at DESC").map(rowToMeta)
        }) ?? []
    }

    public func usedCliSessionIds() -> Set<String> {
        (try? dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT cli_session_id FROM sessions WHERE cli_session_id IS NOT NULL"))
        }) ?? []
    }

    public func search(_ query: String, limit: Int) -> [SearchHit] {
        let match = GRDBStore.toFtsMatch(query)
        guard !match.isEmpty else { return [] }
        return (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, snippet(sessions_fts, 2, '[', ']', '…', 12) AS snippet
                FROM sessions_fts f
                JOIN sessions s ON s.id = f.session_id
                WHERE sessions_fts MATCH ?
                ORDER BY bm25(sessions_fts), s.updated_at DESC
                LIMIT ?
                """, arguments: [match, limit])
                .map { SearchHit(meta: rowToMeta($0), snippet: $0["snippet"]) }
        }) ?? []
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        (try? dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM diff_comments WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM diff_reviews WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM message_queue WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }) ?? false
    }

    /// Retention cap (juancode-477): keep at most `perProject` sessions per project,
    /// hard-deleting the oldest beyond the cap. Sessions are grouped by
    /// `projectKey(cwd)` (defaults to `projectCwd`, folding worktrees into their
    /// repo); within a group the newest `perProject` by `created_at` survive.
    /// `keepIds` are never deleted — pass the currently-live session ids so an
    /// in-flight pty is never pruned even if it sorts past the cap. A `perProject`
    /// ≤ 0 disables the cap (no-op). Returns the deleted ids.
    @discardableResult
    public func enforceSessionCap(
        perProject: Int = Config.sessionsPerProjectCap,
        projectKey: (String) -> String = { projectCwd(for: $0) },
        keepIds: Set<String> = []
    ) -> [String] {
        guard perProject > 0 else { return [] }
        // Newest-first, so a simple running count per project keeps the top N.
        var seen: [String: Int] = [:]
        var toDelete: [String] = []
        for meta in list() {
            let key = projectKey(meta.cwd)
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > perProject, !keepIds.contains(meta.id) {
                toDelete.append(meta.id)
            }
        }
        for id in toDelete { delete(id) }
        return toDelete
    }

    public func markOrphansExited() {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET status = 'exited' WHERE status = 'running'")
        }
    }

    // MARK: - PersistentStore: comments

    public func addComment(_ c: DiffComment) {
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO diff_comments (id, session_id, file, side, line, end_line, body, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.id, c.sessionId, c.file, c.side.rawValue, c.line, c.endLine, c.body, c.createdAt])
        }
    }

    public func listComments(_ sessionId: String) -> [DiffComment] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM diff_comments WHERE session_id = ? ORDER BY created_at ASC",
                             arguments: [sessionId])
                .map { r in
                    DiffComment(
                        id: r["id"], sessionId: r["session_id"], file: r["file"],
                        side: (r["side"] as String) == "old" ? .old : .new,
                        line: r["line"], endLine: r["end_line"], body: r["body"], createdAt: r["created_at"]
                    )
                }
        }) ?? []
    }

    @discardableResult
    public func removeComment(_ sessionId: String, _ id: String) -> Bool {
        (try? dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM diff_comments WHERE id = ? AND session_id = ?",
                           arguments: [id, sessionId])
            return db.changesCount > 0
        }) ?? false
    }

    @discardableResult
    public func clearComments(_ sessionId: String) -> Int {
        (try? dbQueue.write { db -> Int in
            try db.execute(sql: "DELETE FROM diff_comments WHERE session_id = ?", arguments: [sessionId])
            return db.changesCount
        }) ?? 0
    }

    // MARK: - PersistentStore: reviews

    public func saveReview(_ sessionId: String, _ result: ReviewResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let payload = String(decoding: data, as: UTF8.self)
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO diff_reviews (session_id, payload, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET payload = excluded.payload, created_at = excluded.created_at
                """, arguments: [sessionId, payload, result.createdAt])
        }
    }

    public func getReview(_ sessionId: String) -> ReviewResult? {
        let payload = try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM diff_reviews WHERE session_id = ?",
                                arguments: [sessionId])
        } ?? nil
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReviewResult.self, from: data)
    }

    // MARK: - MessageQueuePersistence (oracle-cj3 / juancode-r82)

    @discardableResult
    public func add(_ sessionId: String, text: String) -> QueuedMessage {
        let item = QueuedMessage(text: text)
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO message_queue (id, session_id, text, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [item.id, sessionId, item.text, item.createdAt])
        }
        return item
    }

    public func list(_ sessionId: String) -> [QueuedMessage] {
        (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, text, created_at FROM message_queue WHERE session_id = ? ORDER BY rowid ASC",
                arguments: [sessionId]
            ).map { QueuedMessage(id: $0["id"], text: $0["text"], createdAt: $0["created_at"]) }
        }) ?? []
    }

    public func first(_ sessionId: String) -> QueuedMessage? {
        (try? dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, text, created_at FROM message_queue WHERE session_id = ? ORDER BY rowid ASC LIMIT 1",
                arguments: [sessionId]
            ).map { QueuedMessage(id: $0["id"], text: $0["text"], createdAt: $0["created_at"]) }
        }) ?? nil
    }

    @discardableResult
    public func remove(_ sessionId: String, _ id: String) -> Bool {
        (try? dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM message_queue WHERE id = ? AND session_id = ?",
                           arguments: [id, sessionId])
            return db.changesCount > 0
        }) ?? false
    }

    // MARK: - FTS query building

    /// Turn free-text input into a safe FTS5 MATCH expression: each whitespace
    /// token becomes a quoted, prefix-matched term ANDed together. Mirrors
    /// `toFtsMatch` in db.ts so stray quotes/operators can't cause a syntax error.
    public static func toFtsMatch(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }
}
