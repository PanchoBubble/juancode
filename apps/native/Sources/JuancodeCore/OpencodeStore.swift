import Foundation
import SQLite3

/// Read-only view of opencode's own database — the opencode analogue of the JSONL
/// transcripts `SessionTitle`/`RecoverSession` read for claude and codex.
///
/// It reads rows and titles, and no longer reads usage or message parts: those were
/// the opencode halves of the Swift usage reader and activity tail, both deleted in
/// favour of `juancoded-core/src/usage.rs` and `juancoded-transcripts`.
///
/// opencode keeps everything in one SQLite file (default
/// `~/.local/share/opencode/opencode.db`): a `session` row per conversation with its
/// `directory`, generated `title`, timestamps, cumulative token counts and cost, plus
/// `message`/`part` rows carrying the turns. That makes it a strictly better source
/// than scraping the TUI: the ids are the ones `opencode --session <id>` resumes, and
/// the token/cost figures are opencode's own accounting rather than our estimate.
///
/// Everything here opens the database READ-ONLY and never writes, so a live opencode
/// holding the WAL is unaffected — we are a reader of its data, never a second writer.
public enum OpencodeStore {
    /// Where opencode keeps its data (`XDG_DATA_HOME`, else `~/.local/share`), the same
    /// resolution opencode's own `Global.Path.data` does.
    static var dataDir: String {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/opencode")
    }

    /// The database file to read.
    ///
    /// `JUANCODE_OPENCODE_DB` wins (tests point it at a fixture), then opencode's own
    /// `OPENCODE_DB` (absolute, or relative to the data dir — its rule, not ours). With
    /// neither set it's `opencode.db`, and if that doesn't exist we take the newest
    /// `opencode*.db` in the data dir, which is where a non-release channel puts its
    /// own file (`opencode-dev.db`).
    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let ours = env["JUANCODE_OPENCODE_DB"], !ours.isEmpty { return ours }
        if let theirs = env["OPENCODE_DB"], !theirs.isEmpty {
            return theirs.hasPrefix("/")
                ? theirs
                : (dataDir as NSString).appendingPathComponent(theirs)
        }
        let fm = FileManager.default
        let release = (dataDir as NSString).appendingPathComponent("opencode.db")
        if fm.fileExists(atPath: release) { return release }
        let others = (try? fm.contentsOfDirectory(atPath: dataDir))?
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .map { (dataDir as NSString).appendingPathComponent($0) } ?? []
        let newest = others.max { lhs, rhs in (mtimeMs(lhs) ?? 0) < (mtimeMs(rhs) ?? 0) }
        return newest ?? release
    }

    private static func mtimeMs(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - rows

    /// One opencode conversation, as much of its `session` row as we use.
    public struct SessionRow: Sendable, Equatable {
        public let id: String
        public let directory: String
        public let title: String
        public let createdMs: Int
        public let updatedMs: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let costUsd: Double
        /// Set for a sub-agent's session, which belongs to its parent conversation and
        /// is never resumed on its own.
        public let parentId: String?
    }

    /// `session` columns, in the order every query below selects them.
    private static let sessionColumns = """
        id, directory, title, time_created, time_updated, \
        tokens_input, tokens_output, tokens_reasoning, \
        tokens_cache_read, tokens_cache_write, cost, parent_id
        """

    private static func row(_ r: [SqlValue]) -> SessionRow? {
        guard r.count >= 12, let id = r[0].text, !id.isEmpty else { return nil }
        return SessionRow(
            id: id,
            directory: r[1].text ?? "",
            title: r[2].text ?? "",
            createdMs: r[3].int ?? 0,
            updatedMs: r[4].int ?? 0,
            inputTokens: r[5].int ?? 0,
            outputTokens: r[6].int ?? 0,
            reasoningTokens: r[7].int ?? 0,
            cacheReadTokens: r[8].int ?? 0,
            cacheWriteTokens: r[9].int ?? 0,
            costUsd: r[10].double ?? 0,
            parentId: r[11].text)
    }

    /// One session by id, or nil when the database has no such row (yet).
    public static func session(_ id: String, db: String = defaultPath) -> SessionRow? {
        let rows = OpencodeSqlite.query(
            db, "SELECT \(sessionColumns) FROM session WHERE id = ?1 LIMIT 1", [.text(id)])
        return rows.first.flatMap(row)
    }

    /// The forms a directory can be recorded under: as given, and with symlinks
    /// resolved. opencode stores the path it was launched in, which for a worktree or
    /// anything under `/tmp` can be the resolved one while ours is the symlinked one
    /// (or the reverse), so both are matched.
    static func directoryVariants(_ directory: String) -> [String] {
        let resolved = (directory as NSString).resolvingSymlinksInPath
        return resolved == directory ? [directory] : [directory, resolved]
    }

    /// Every top-level conversation that ran in `directory`, newest first.
    public static func sessions(directory: String, db: String = defaultPath) -> [SessionRow] {
        let dirs = directoryVariants(directory)
        let placeholders = (1...dirs.count).map { "?\($0)" }.joined(separator: ", ")
        return OpencodeSqlite.query(
            db,
            """
            SELECT \(sessionColumns) FROM session
            WHERE directory IN (\(placeholders)) AND parent_id IS NULL AND time_archived IS NULL
            ORDER BY time_created DESC
            """,
            dirs.map { SqlValue.text($0) }
        ).compactMap(row)
    }

    /// The `limit` most recently touched top-level conversations, newest first — the
    /// candidate pool for the "conversations you started in a terminal" list.
    public static func recentSessions(limit: Int, db: String = defaultPath) -> [SessionRow] {
        OpencodeSqlite.query(
            db,
            """
            SELECT \(sessionColumns) FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL
            ORDER BY time_updated DESC LIMIT ?1
            """,
            [.int(limit)]
        ).compactMap(row)
    }

    // MARK: - post-spawn id discovery

    /// One scan pass: the newest conversation in `cwd` created at/after `sinceMs`.
    static func scanOnce(cwd: String, sinceMs: Int, db: String = defaultPath) -> String? {
        // Same clock-skew grace as the Codex scanner.
        let floor = sinceMs - 2000
        let dirs = directoryVariants(cwd)
        let placeholders = (1...dirs.count).map { "?\($0)" }.joined(separator: ", ")
        return OpencodeSqlite.query(
            db,
            """
            SELECT id FROM session
            WHERE directory IN (\(placeholders)) AND parent_id IS NULL
              AND time_created >= ?\(dirs.count + 1)
            ORDER BY time_created DESC LIMIT 1
            """,
            dirs.map { SqlValue.text($0) } + [.int(floor)]
        ).first?.first?.text
    }

    /// Poll for the session opencode created at/after `sinceMs` in `cwd`, mirroring
    /// `CodexSessionDiscovery.capture`: opencode has no flag to pin an id, and it only
    /// writes the row once the TUI has booted, so the id lands a moment after spawn.
    /// opencode writes the session row when the FIRST message is sent, not when the TUI
    /// boots (unlike Codex, whose rollout file appears at startup). So the id can be
    /// minutes away — the window matches `recoverCliSessionId`'s 15-minute one, past
    /// which a cwd match stops being trustworthy anyway. Each pass is one indexed
    /// lookup, so waiting is cheap.
    public static let captureTimeoutMs = 15 * 60_000

    public static func capture(
        cwd: String,
        sinceMs: Int,
        timeoutMs: Int = captureTimeoutMs,
        intervalMs: Int = 1500,
        db: String = defaultPath
    ) async -> String? {
        let deadline = sinceMs + timeoutMs
        while true {
            if let id = scanOnce(cwd: cwd, sinceMs: sinceMs, db: db) { return id }
            if Int(Date().timeIntervalSince1970 * 1000) >= deadline { return nil }
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }

    // MARK: - title

    /// opencode names a brand-new conversation `New session - <ISO timestamp>` until the
    /// model summarizes it. That's less useful than our own "opencode · <folder>"
    /// placeholder, so it doesn't count as a title.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.range(of: "^New session\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The conversation's own title, or nil while it's still opencode's placeholder.
    public static func title(_ id: String, db: String = defaultPath) -> String? {
        guard let row = session(id, db: db) else { return nil }
        let raw = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || isPlaceholderTitle(raw) { return nil }
        return tidy(raw)
    }
}

// MARK: - the minimum SQLite reader we need

/// A value read from (or bound to) SQLite. Only the three types opencode's columns
/// use, plus null.
enum SqlValue {
    case text(String)
    case int(Int)
    case double(Double)
    case null

    var text: String? { if case let .text(s) = self { return s }; return nil }
    var int: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        case let .text(s): return Int(s)
        case .null: return nil
        }
    }
    var double: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        case let .text(s): return Double(s)
        case .null: return nil
        }
    }
}

/// A read-only SQLite query, opened and closed per call.
///
/// Per-call open is deliberate: opencode is the writer, and holding a connection open
/// across polls would pin a WAL snapshot and keep returning stale rows. Opening costs
/// microseconds against a poll interval measured in seconds.
enum OpencodeSqlite {
    /// Run `sql` with positional binds and return the rows. Any failure (missing file,
    /// locked database, schema drift) yields an empty result — the callers all treat
    /// "nothing yet" as a normal outcome, so a broken read degrades to no title / no
    /// usage rather than an error path.
    static func query(_ path: String, _ sql: String, _ binds: [SqlValue] = []) -> [[SqlValue]] {
        var handle: OpaquePointer?
        // READONLY|NOMUTEX: we never write, and each connection is used on one thread.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(db) }
        // opencode writes in short transactions; wait briefly rather than fail a poll.
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        for (i, bind) in binds.enumerated() {
            let index = Int32(i + 1)
            switch bind {
            case let .text(s): sqlite3_bind_text(statement, index, s, -1, SQLITE_TRANSIENT)
            case let .int(v): sqlite3_bind_int64(statement, index, Int64(v))
            case let .double(d): sqlite3_bind_double(statement, index, d)
            case .null: sqlite3_bind_null(statement, index)
            }
        }

        return collect(statement)
    }

    /// Run statements that produce no rows, creating `path` if it doesn't exist.
    /// Read-only is the rule for opencode's own database — this exists so tests can
    /// build a fixture with the same schema, and nothing in the app calls it.
    @discardableResult
    static func exec(_ path: String, _ sql: String) -> Bool {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func collect(_ statement: OpaquePointer) -> [[SqlValue]] {
        var rows: [[SqlValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            var row: [SqlValue] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER:
                    row.append(.int(Int(sqlite3_column_int64(statement, c))))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(statement, c)))
                case SQLITE_TEXT:
                    if let cString = sqlite3_column_text(statement, c) {
                        row.append(.text(String(cString: cString)))
                    } else {
                        row.append(.null)
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

/// `SQLITE_TRANSIENT` isn't exposed to Swift; this is its definition (sqlite copies
/// the bound bytes, so a Swift String's storage doesn't have to outlive the bind).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
