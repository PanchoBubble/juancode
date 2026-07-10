import Foundation

/// Persistence seam for session metadata + scrollback (mirrors the surface of
/// `sessionDb` used by `session.ts`). u34.2 ships only the in-memory impl; the
/// GRDB/SQLite store lands in u34.5 behind this same protocol.
public protocol SessionStore: AnyObject, Sendable {
    func insert(_ meta: SessionMeta)
    /// Full write: metadata columns + scrollback + FTS reindex. The heavy path, so
    /// callers reserve it for moments that need fresh search (busy->idle edge, exit,
    /// resume/seed). Use `updateMeta` / `updateScrollback` for the hot paths.
    func update(_ meta: SessionMeta, scrollback: [UInt8])
    /// Persist a metadata edit (title / usage / status / flags) WITHOUT rewriting the
    /// (potentially 256KiB) scrollback column (juancode-5qw.1). Pass
    /// `reindexTitleFts: true` when the title changed so search reflects the rename;
    /// the reindex reuses the already-stored scrollback text, never re-serializing
    /// the live ring.
    func updateMeta(_ meta: SessionMeta, reindexTitleFts: Bool)
    /// Persist scrollback only — the periodic crash-safety flush of a running
    /// session. Skips the metadata columns and, deliberately, the FTS reindex: a busy
    /// session's searchable scrollback is refreshed on the busy->idle edge / exit via
    /// `update` (its live output is already visible, so second-fresh search of a
    /// running session isn't needed).
    func updateScrollback(_ id: String, scrollback: [UInt8], updatedAt: Int)
    func setCliSessionId(_ id: String, cliSessionId: String)
    /// Rename a session: persist a new title (also refreshes the FTS index).
    func setTitle(_ id: String, title: String)
    /// Archive / unarchive a session: hides it from the default sidebar list
    /// while keeping its row + scrollback intact.
    func setArchived(_ id: String, archived: Bool)
    /// Persisted scrollback for `id`, used to seed a resumed pty so history
    /// carries forward across reactivation.
    func getScrollback(_ id: String) -> [UInt8]?
}

/// The full persistence surface the HTTP/WS server needs: the `SessionStore`
/// write-path (above) plus the read/admin queries, inline diff comments, and
/// cached AI reviews. Mirrors the `sessionDb` / `commentDb` / `reviewDb` exports
/// of `apps/server/src/db.ts`. Both `InMemorySessionStore` (tests) and the GRDB
/// store (u34.5) conform, so the server can be exercised without sqlite.
public protocol PersistentStore: SessionStore {
    // sessions — read / admin
    func get(_ id: String) -> SessionMeta?
    func list() -> [SessionMeta]
    func usedCliSessionIds() -> Set<String>
    func search(_ query: String, limit: Int) -> [SearchHit]
    @discardableResult func delete(_ id: String) -> Bool
    /// On startup, mark any session still "running" as exited (its pty died with
    /// the previous process).
    func markOrphansExited()

    // inline diff comments
    func addComment(_ c: DiffComment)
    func listComments(_ sessionId: String) -> [DiffComment]
    @discardableResult func removeComment(_ sessionId: String, _ id: String) -> Bool
    @discardableResult func clearComments(_ sessionId: String) -> Int

    // cached 'Review with Claude' results
    func saveReview(_ sessionId: String, _ result: ReviewResult)
    func getReview(_ sessionId: String) -> ReviewResult?
}

/// Default store: keeps everything in memory for the current process lifetime.
/// Thread-safe via a lock so the pty read queue and the main thread can both hit it.
public final class InMemorySessionStore: PersistentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var metas: [String: SessionMeta] = [:]
    private var scrollbacks: [String: [UInt8]] = [:]
    private var comments: [String: [DiffComment]] = [:]
    private var reviews: [String: ReviewResult] = [:]

    public init() {}

    public func insert(_ meta: SessionMeta) {
        lock.withLock { metas[meta.id] = meta }
    }

    public func update(_ meta: SessionMeta, scrollback: [UInt8]) {
        lock.withLock {
            metas[meta.id] = meta
            scrollbacks[meta.id] = scrollback
        }
    }

    public func updateMeta(_ meta: SessionMeta, reindexTitleFts: Bool) {
        // Scrollback map left untouched; the naive search reads titles live so the
        // `reindexTitleFts` hint is a no-op here.
        lock.withLock { metas[meta.id] = meta }
    }

    public func updateScrollback(_ id: String, scrollback: [UInt8], updatedAt: Int) {
        lock.withLock {
            scrollbacks[id] = scrollback
            if var m = metas[id] {
                m.updatedAt = updatedAt
                metas[id] = m
            }
        }
    }

    public func setCliSessionId(_ id: String, cliSessionId: String) {
        lock.withLock {
            if var m = metas[id] {
                m.cliSessionId = cliSessionId
                metas[id] = m
            }
        }
    }

    public func setTitle(_ id: String, title: String) {
        lock.withLock {
            if var m = metas[id] {
                m.title = title
                m.updatedAt = nowMs()
                metas[id] = m
            }
        }
    }

    public func setArchived(_ id: String, archived: Bool) {
        lock.withLock {
            if var m = metas[id] {
                m.archived = archived
                m.updatedAt = nowMs()
                metas[id] = m
            }
        }
    }

    public func getScrollback(_ id: String) -> [UInt8]? {
        lock.withLock { scrollbacks[id] }
    }

    // MARK: - PersistentStore: read / admin

    public func get(_ id: String) -> SessionMeta? {
        lock.withLock { metas[id] }
    }

    /// Newest-first, matching `db.ts` (`ORDER BY created_at DESC`).
    public func list() -> [SessionMeta] {
        lock.withLock { metas.values.sorted { $0.createdAt > $1.createdAt } }
    }

    public func usedCliSessionIds() -> Set<String> {
        lock.withLock { Set(metas.values.compactMap { $0.cliSessionId }) }
    }

    /// Naive substring search over title + scrollback (the GRDB store uses FTS5).
    /// Good enough for tests; ranks title hits first then recency.
    public func search(_ query: String, limit: Int) -> [SearchHit] {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        return lock.withLock {
            metas.values.compactMap { meta -> SearchHit? in
                let title = meta.title.lowercased()
                let scroll = String(decoding: scrollbacks[meta.id] ?? [], as: UTF8.self).lowercased()
                guard tokens.allSatisfy({ title.contains($0) || scroll.contains($0) }) else { return nil }
                return SearchHit(meta: meta, snippet: meta.title)
            }
            .sorted { $0.meta.updatedAt > $1.meta.updatedAt }
            .prefix(limit)
            .map { $0 }
        }
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        lock.withLock {
            comments[id] = nil
            reviews[id] = nil
            scrollbacks[id] = nil
            return metas.removeValue(forKey: id) != nil
        }
    }

    public func markOrphansExited() {
        lock.withLock {
            for (id, var m) in metas where m.status == .running {
                m.status = .exited
                metas[id] = m
            }
        }
    }

    // MARK: - PersistentStore: comments

    public func addComment(_ c: DiffComment) {
        lock.withLock { comments[c.sessionId, default: []].append(c) }
    }

    public func listComments(_ sessionId: String) -> [DiffComment] {
        lock.withLock { (comments[sessionId] ?? []).sorted { $0.createdAt < $1.createdAt } }
    }

    @discardableResult
    public func removeComment(_ sessionId: String, _ id: String) -> Bool {
        lock.withLock {
            guard var list = comments[sessionId] else { return false }
            let before = list.count
            list.removeAll { $0.id == id }
            comments[sessionId] = list
            return list.count < before
        }
    }

    @discardableResult
    public func clearComments(_ sessionId: String) -> Int {
        lock.withLock {
            let n = comments[sessionId]?.count ?? 0
            comments[sessionId] = nil
            return n
        }
    }

    // MARK: - PersistentStore: reviews

    public func saveReview(_ sessionId: String, _ result: ReviewResult) {
        lock.withLock { reviews[sessionId] = result }
    }

    public func getReview(_ sessionId: String) -> ReviewResult? {
        lock.withLock { reviews[sessionId] }
    }

    // Test/inspection helpers.
    public func meta(_ id: String) -> SessionMeta? {
        lock.withLock { metas[id] }
    }

    public var allMeta: [SessionMeta] {
        lock.withLock { Array(metas.values) }
    }
}
