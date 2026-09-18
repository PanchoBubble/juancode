import Foundation
import GRDB
import JuancodeCore

/// SQLite-backed `PersistentStore` (juancode-u34.5), a faithful port of
/// `apps/server/src/db.ts` onto GRDB. Persists session metadata + capped
/// scrollback, GitHub-PR-style inline diff comments, cached 'Review with Claude'
/// results, and a title/scrollback scan behind `search` so history (and search)
/// survive app restarts.
///
/// Schema-compatible with the Node `juancode.db`: scrollback is stored as TEXT
/// (a lossy UTF-8 decode of the raw pty bytes) so the same data dir is readable
/// by either implementation. Replay fidelity is preserved end to end because the
/// trim happens on byte boundaries upstream (see `Scrollback`).
public final class GRDBStore: PersistentStore, MessageQueuePersistence, TrackedPrStore, @unchecked Sendable {
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
        let droppedFts = try dbQueue.write { db -> Bool in
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
                    mid_turn         INTEGER NOT NULL DEFAULT 0,
                    dispatch_id      TEXT,
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
            if !cols.contains("dispatch_id") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN dispatch_id TEXT")
            }
            if !cols.contains("mid_turn") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN mid_turn INTEGER NOT NULL DEFAULT 0")
            }
            // The grid the `scrollback` column was PARSED at (juancode-r5cf). 0 means
            // "never recorded" — a row written before this column existed, which a
            // reader must treat as unknown rather than as a width.
            if !cols.contains("scrollback_cols") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN scrollback_cols INTEGER NOT NULL DEFAULT 0")
            }
            if !cols.contains("scrollback_rows") {
                try db.execute(sql: "ALTER TABLE sessions ADD COLUMN scrollback_rows INTEGER NOT NULL DEFAULT 0")
            }

            // A covering index over exactly `metaColumns`, so `list()` reads the
            // sidebar's session list straight out of the index and never opens a
            // `sessions` row — whose `scrollback` column makes almost every row spill
            // into an overflow chain that the meta columns stored after it would
            // otherwise have to be walked through. See `metaColumns`.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_sessions_meta ON sessions(
                    created_at DESC, id, provider, cwd, title, status, exit_code, updated_at,
                    cli_session_id, skip_permissions, worktree_path, usage, archived, dormant,
                    dispatch_id
                );
                """)

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

            // Tracked-PR watch list (juancode-b4m): id = TrackedPr.key(cwd:number:),
            // payload = JSON-encoded TrackedPr. Owned exclusively by PrTrackingEngine;
            // replaces the legacy `juancode.trackedPrs.v1` UserDefaults blob.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tracked_prs (
                    id         TEXT PRIMARY KEY,
                    payload    TEXT NOT NULL,
                    updated_at INTEGER NOT NULL
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

            return try Self.dropTheFtsIndex(db)
        }
        // Outside the migration's transaction, because VACUUM cannot run inside one.
        if droppedFts {
            try? dbQueue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        }
    }

    /// Drop the fts5 index over `sessions(title, scrollback)`, and give the file back.
    ///
    /// The index was a second copy of every scrollback (juancode-5bwj). Measured on
    /// the real mirror on 2026-09-18: a 255 MB file holding 105 MB of scrollback in
    /// `sessions`, the same 105 MB again in `sessions_fts_content`, and 30 MB of
    /// index — 53% of the file was the duplicate and its index. Writing it was the
    /// other half of the cost: 325 of 392 write-queue samples in 5bwj were inside
    /// `syncFts`, tokenizing a ring that had just been tokenized.
    ///
    /// Not replaced with an external-content fts5, which would have fixed the
    /// duplicate and kept the index. Search on this store is a fallback now — the
    /// daemon holds every session's history and answers `searchSessions` from it
    /// (juancode-rz4c), and this file only ever sees the bytes of sessions this Mac
    /// attached to — so it is not worth an index at all, and `search` below scans.
    ///
    /// `DROP TABLE` on the virtual table takes its four shadow tables with it, and the
    /// VACUUM the caller then runs is what actually gives the pages back — without it
    /// the file keeps every one of them on the freelist, since `performMaintenance`
    /// only vacuums past a threshold. Returning whether anything was dropped is how
    /// that VACUUM stays a once-per-file cost instead of a once-per-launch one.
    ///
    /// Measured on a copy of the real mirror, 2026-09-18: 267.4 MB to 117.0 MB, 0.9s
    /// to drop and 1.9s to vacuum, with all 882 sessions and all 110.6 MB of their
    /// scrollback still there. That ~3s lands on the first launch after this ships,
    /// once, inside the open — which is where the schema already is.
    private static func dropTheFtsIndex(_ db: Database) throws -> Bool {
        let present = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions_fts'"
        ) ?? 0
        guard present > 0 else { return false }
        try db.execute(sql: "DROP TABLE sessions_fts")
        return true
    }

    // MARK: - maintenance (juancode-hv06)

    /// What one maintenance pass did, for logging / tests.
    public struct MaintenanceReport: Sendable, Equatable {
        /// Pages on the freelist before the pass.
        public var freelistPagesBefore: Int
        /// Total database size in pages after the pass.
        public var pageCountAfter: Int
        /// Whether a VACUUM actually ran (it only does past the threshold).
        public var vacuumed: Bool
    }

    /// Compact the database: if enough pages are sitting on the freelist, rewrite the
    /// file to give the space back.
    ///
    /// Deletes (the per-project retention cap, `enforceSessionCap`) return pages to
    /// SQLite's freelist but never to the filesystem, and nothing in the app had ever
    /// reclaimed them. Measured on a real db: 445 MB total, ~24 MB of it freelist.
    ///
    /// It used to compact the fts5 index here too; there is no index to compact since
    /// that table was dropped, and the one VACUUM its removal needs runs in `migrate`.
    ///
    /// VACUUM is slow (seconds, on a large file) and takes a write lock, so this
    /// belongs on a background queue at launch — never on a path a frame waits on.
    /// `vacuumIfFreelistPagesExceeds` keeps a routine launch from rewriting the whole
    /// file for a few stray pages.
    @discardableResult
    public func performMaintenance(vacuumIfFreelistPagesExceeds threshold: Int = 2_000) throws -> MaintenanceReport {
        // VACUUM cannot run inside a transaction, so this deliberately avoids `write`.
        try dbQueue.writeWithoutTransaction { db in
            let freelist = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0

            var vacuumed = false
            if freelist > threshold {
                try db.execute(sql: "VACUUM")
                vacuumed = true
            }

            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            return MaintenanceReport(freelistPagesBefore: freelist, pageCountAfter: pages,
                                     vacuumed: vacuumed)
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
            dormant: (r["dormant"] as Int? ?? 0) == 1,
            dispatchId: r["dispatch_id"]
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

    /// Lossy UTF-8 view of raw scrollback bytes, for the TEXT column.
    private static func scrollbackText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - SessionStore (write-path)

    public func insert(_ meta: SessionMeta) {
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, provider, cwd, title, status, exit_code, cli_session_id,
                                      scrollback, skip_permissions, worktree_path, usage, archived, dormant, dispatch_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    meta.id, meta.provider.rawValue, meta.cwd, meta.title, meta.status.rawValue,
                    meta.exitCode, meta.cliSessionId, meta.skipPermissions ? 1 : 0,
                    meta.worktreePath, Self.encodeUsage(meta.usage), meta.archived ? 1 : 0,
                    meta.dormant ? 1 : 0, meta.dispatchId, meta.createdAt, meta.updatedAt,
                ])
        }
    }

    public func update(_ meta: SessionMeta, scrollback: [UInt8]) {
        let text = Self.scrollbackText(scrollback)
        try? dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sessions
                SET title = ?, status = ?, exit_code = ?, cli_session_id = ?, scrollback = ?,
                    skip_permissions = ?, worktree_path = ?, usage = ?, archived = ?, dormant = ?, dispatch_id = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    meta.title, meta.status.rawValue, meta.exitCode, meta.cliSessionId, text,
                    meta.skipPermissions ? 1 : 0, meta.worktreePath, Self.encodeUsage(meta.usage),
                    meta.archived ? 1 : 0, meta.dormant ? 1 : 0, meta.dispatchId, meta.updatedAt, meta.id,
                ])
        }
    }

    /// Persist a metadata edit without rewriting the (up to 256KiB) scrollback column
    /// (juancode-5qw.1).
    public func updateMeta(_ meta: SessionMeta) {
        try? dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sessions
                SET title = ?, status = ?, exit_code = ?, cli_session_id = ?,
                    skip_permissions = ?, worktree_path = ?, usage = ?, archived = ?, dormant = ?, dispatch_id = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    meta.title, meta.status.rawValue, meta.exitCode, meta.cliSessionId,
                    meta.skipPermissions ? 1 : 0, meta.worktreePath, Self.encodeUsage(meta.usage),
                    meta.archived ? 1 : 0, meta.dormant ? 1 : 0, meta.dispatchId, meta.updatedAt, meta.id,
                ])
        }
    }

    /// Crash-safety flush of a running session's scrollback — the column plus
    /// `updated_at`, nothing else.
    public func updateScrollback(_ id: String, scrollback: [UInt8], updatedAt: Int) {
        let text = Self.scrollbackText(scrollback)
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET scrollback = ?, updated_at = ? WHERE id = ?",
                arguments: [text, updatedAt, id]
            )
        }
    }

    /// Record the grid the stored scrollback was parsed at. Written on the grid's own
    /// edge (spawn, resize), not per flush — see `SessionStore.setScrollbackGrid`.
    public func setScrollbackGrid(_ id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET scrollback_cols = ?, scrollback_rows = ? WHERE id = ?",
                arguments: [cols, rows, id]
            )
        }
    }

    public func getScrollbackGrid(_ id: String) -> (cols: Int, rows: Int)? {
        try? dbQueue.read { db -> (cols: Int, rows: Int)? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT scrollback_cols, scrollback_rows FROM sessions WHERE id = ?",
                arguments: [id])
            else { return nil }
            let c: Int = row["scrollback_cols"] ?? 0
            let r: Int = row["scrollback_rows"] ?? 0
            return c > 0 && r > 0 ? (c, r) : nil
        } ?? nil
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

    /// One-column write on the busy edge (twice per turn). Deliberately leaves
    /// `updated_at` alone: this is a liveness marker for the next launch, not a
    /// content change, and bumping it would reshuffle every recency-ordered list.
    public func setMidTurn(_ id: String, _ midTurn: Bool) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET mid_turn = ? WHERE id = ?",
                arguments: [midTurn ? 1 : 0, id]
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

    /// Every column `rowToMeta` reads — deliberately NOT `SELECT *`, which also hauls
    /// the `scrollback` TEXT column (up to the ring cap per row) out of SQLite and
    /// decodes it just for `rowToMeta` to throw it away. The sidebar rebuild runs
    /// `list()` on the main actor, so with a few dozen persisted sessions that was
    /// megabytes of pointless main-thread work per refresh (juancode-mapj).
    ///
    /// Naming the columns is necessary but not sufficient: `scrollback` sits PHYSICALLY
    /// before half of them in the row, and a row whose payload spills past one page
    /// keeps the remainder in an overflow chain. So reading `skip_permissions` or
    /// anything after it still walks every overflow page of that row's scrollback —
    /// `list()` measured 329ms of main-thread `pread` over 728 rows / 149MB. That is
    /// what `idx_sessions_meta` is for: it carries exactly this projection, so the
    /// scan is index-only and never opens a table row (1ms). Adding a column here
    /// means adding it to that index too — `testListUsesCoveringIndex` fails otherwise.
    static let metaColumns = """
        id, provider, cwd, title, status, exit_code, created_at, updated_at, \
        cli_session_id, skip_permissions, worktree_path, usage, archived, dormant, dispatch_id
        """

    /// The exact statement `list()` runs, shared with the test that asserts its plan.
    static let listSQL = "SELECT \(metaColumns) FROM sessions ORDER BY created_at DESC"

    public func get(_ id: String) -> SessionMeta? {
        try? dbQueue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT \(Self.metaColumns) FROM sessions WHERE id = ?", arguments: [id]
            ).map(rowToMeta)
        } ?? nil
    }

    public func list() -> [SessionMeta] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: Self.listSQL).map(rowToMeta)
        }) ?? []
    }

    /// SQLite's plan for `sql`, so a test can pin `list()` to its covering index —
    /// the difference between an index-only scan and a 329ms main-thread table walk
    /// is invisible in a functional test (see `metaColumns`). Not part of the public
    /// API: `@testable` is the only caller.
    func queryPlan(_ sql: String) -> [String] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)").map { $0["detail"] as String }
        }) ?? []
    }

    /// Run `sql` against this store. `@testable` only, and for one job: putting an
    /// old file's shape BACK so the migration that removes it can be measured. A test
    /// that builds the pre-migration file by hand is the only test that proves the
    /// migration does anything.
    func rawWriteForTesting(_ sql: String) throws {
        try dbQueue.write { db in try db.execute(sql: sql) }
    }

    /// The first column of every row `sql` returns, as strings. Same caller, same
    /// reason: a test asserting a table is gone has to be able to ask sqlite_master.
    func rawQueryForTesting(_ sql: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: sql) }
    }

    public func usedCliSessionIds() -> Set<String> {
        (try? dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT cli_session_id FROM sessions WHERE cli_session_id IS NOT NULL"))
        }) ?? []
    }

    /// Sessions whose title or scrollback contains `query`, newest first.
    ///
    /// A scan, where this used to be an fts5 `MATCH` with a bm25 ranking. Two reasons
    /// the index is not worth keeping. It was a second copy of every scrollback
    /// (juancode-5bwj) — 53% of a 255 MB file, measured 2026-09-18 — and it was the
    /// busiest thing on the write queue, retokenizing a ring on every flush. And this
    /// store is no longer the one that answers: the daemon holds every session's
    /// history and answers `searchSessions` from it, so what is left here is the
    /// fallback for a core that does not (juancode-rz4c), over the sessions this Mac
    /// attached to. Measured on the real mirror on 2026-09-18: 105 MB of scrollback
    /// across 520 rows of 882.
    ///
    /// Substring rather than fts5's prefix-per-token, so a search for `ustom` finds
    /// `custom` where the index would not, and a two-word query matches only where the
    /// two words are adjacent. Recency rather than bm25: which session was this about
    /// is answered by the newest one that mentions it, and that is also the order the
    /// daemon answers in, so a fallback result list is not sorted differently from a
    /// real one.
    public func search(_ query: String, limit: Int) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let pattern = "%" + needle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE title LIKE ? ESCAPE '\\' OR scrollback LIKE ? ESCAPE '\\'
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
                """, arguments: [pattern, pattern, limit])
                .map { row in
                    let title: String = row["title"]
                    let scrollback: String = row["scrollback"]
                    let snippet = searchSnippet(in: title, matching: needle)
                        ?? searchSnippet(in: scrollback, matching: needle)
                        ?? ""
                    return SearchHit(meta: rowToMeta(row), snippet: snippet)
                }
        }) ?? []
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        (try? dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM diff_comments WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM diff_reviews WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM message_queue WHERE session_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }) ?? false
    }

    /// Retention cap (juancode-477): keep at most `perProject` sessions per project,
    /// hard-deleting the oldest beyond the cap. Sessions are grouped by
    /// `projectKey(cwd)` (defaults to `projectCwd`, folding worktrees into their
    /// repo); within a group the newest `perProject` by `created_at` survive.
    /// Archived sessions are skipped entirely — they neither consume a cap slot nor
    /// get deleted, so archiving is how you keep a session past the cap. `keepIds`
    /// are never deleted — pass the currently-live and currently-viewed session ids
    /// so an in-flight pty (or a session open in a pane) is never pruned even if it
    /// sorts past the cap. A `perProject` ≤ 0 disables the cap (no-op). Returns the
    /// deleted ids.
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
            if meta.archived { continue }
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

    @discardableResult
    public func markOrphansDormant() -> [String] {
        (try? dbQueue.write { db -> [String] in
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM sessions WHERE status = 'running'")
            guard !ids.isEmpty else { return [] }
            try db.execute(
                sql: "UPDATE sessions SET status = 'exited', dormant = 1 WHERE status = 'running'")
            return ids
        }) ?? []
    }

    @discardableResult
    public func takeMidTurnIds() -> Set<String> {
        (try? dbQueue.write { db -> Set<String> in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE mid_turn = 1")
            guard !ids.isEmpty else { return [] }
            try db.execute(sql: "UPDATE sessions SET mid_turn = 0 WHERE mid_turn = 1")
            return Set(ids)
        }) ?? []
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

    // MARK: - TrackedPrStore (juancode-b4m)

    public func loadTrackedPrPayloads() -> [String: String] {
        (try? dbQueue.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM tracked_prs") {
                out[row["id"] as String] = row["payload"] as String
            }
            return out
        }) ?? [:]
    }

    public func replaceTrackedPrPayloads(_ payloads: [String: String]) {
        let now = nowMs()
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracked_prs")
            for (id, payload) in payloads {
                try db.execute(
                    sql: "INSERT INTO tracked_prs (id, payload, updated_at) VALUES (?, ?, ?)",
                    arguments: [id, payload, now]
                )
            }
        }
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
}
