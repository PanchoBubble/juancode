import XCTest
@testable import JuancodePersistence
import JuancodeCore

final class GRDBStoreTests: XCTestCase {
    private var path: String!
    private var store: GRDBStore!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() as NSString
        path = dir.appendingPathComponent("juancode-test-\(UUID().uuidString).db")
        store = try GRDBStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func meta(
        _ id: String = UUID().uuidString.lowercased(),
        title: String = "Claude · juancode",
        status: SessionStatus = .running,
        cliSessionId: String? = nil,
        createdAt: Int = nowMs(),
        usage: SessionUsage? = nil
    ) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: "/tmp/work", title: title, status: status,
            exitCode: nil, createdAt: createdAt, updatedAt: createdAt,
            cliSessionId: cliSessionId, skipPermissions: false, worktreePath: nil, usage: usage
        )
    }

    func testInsertAndGet() {
        let m = meta()
        store.insert(m)
        let got = store.get(m.id)
        XCTAssertEqual(got, m)
    }

    func testGetMissingReturnsNil() {
        XCTAssertNil(store.get("nope"))
    }

    /// The in-memory fallback used when the on-disk DB can't be opened (juancode-4zk)
    /// opens cleanly, runs migrations, and supports normal reads/writes for the
    /// session — it just doesn't persist across instances.
    func testInMemoryFallbackStoreWorks() throws {
        let mem = try GRDBStore(inMemory: true)
        let m = meta("mem-1")
        mem.insert(m)
        XCTAssertEqual(mem.get("mem-1"), m)
    }

    func testListOrdersNewestFirst() {
        let a = meta("a", createdAt: 1000)
        let b = meta("b", createdAt: 3000)
        let c = meta("c", createdAt: 2000)
        store.insert(a); store.insert(b); store.insert(c)
        XCTAssertEqual(store.list().map(\.id), ["b", "c", "a"])
    }

    func testUpdatePersistsScrollbackAndMeta() {
        var m = meta()
        store.insert(m)
        m.title = "renamed"
        m.status = .exited
        m.exitCode = 0
        let bytes: [UInt8] = Array("hello \u{1B}[31mworld\u{1B}[0m".utf8)
        store.update(m, scrollback: bytes)

        let got = store.get(m.id)
        XCTAssertEqual(got?.title, "renamed")
        XCTAssertEqual(got?.status, .exited)
        XCTAssertEqual(got?.exitCode, 0)
        XCTAssertEqual(store.getScrollback(m.id), bytes)
    }

    func testUsageRoundTrips() {
        let usage = SessionUsage(inputTokens: 10, outputTokens: 20, cacheReadTokens: 5,
                                 cacheWriteTokens: 1, totalTokens: 36, costUsd: 0.0123)
        var m = meta(usage: usage)
        store.insert(m)
        store.update(m, scrollback: [])
        XCTAssertEqual(store.get(m.id)?.usage, usage)
    }

    func testSetCliSessionIdAndUsedIds() {
        let m = meta()
        store.insert(m)
        XCTAssertTrue(store.usedCliSessionIds().isEmpty)
        store.setCliSessionId(m.id, cliSessionId: "cli-123")
        XCTAssertEqual(store.get(m.id)?.cliSessionId, "cli-123")
        XCTAssertEqual(store.usedCliSessionIds(), ["cli-123"])
    }

    func testDeleteCascadesCommentsAndReview() {
        let m = meta()
        store.insert(m)
        store.addComment(DiffComment(id: "c1", sessionId: m.id, file: "a.ts", side: .new,
                                     line: 1, endLine: 1, body: "hi", createdAt: nowMs()))
        store.saveReview(m.id, ReviewResult(status: .ok, findings: [], summary: "ok", createdAt: nowMs()))

        XCTAssertTrue(store.delete(m.id))
        XCTAssertNil(store.get(m.id))
        XCTAssertTrue(store.listComments(m.id).isEmpty)
        XCTAssertNil(store.getReview(m.id))
        XCTAssertFalse(store.delete(m.id)) // already gone
    }

    func testMarkOrphansExited() {
        store.insert(meta("running", status: .running))
        store.insert(meta("done", status: .exited))
        store.markOrphansExited()
        XCTAssertEqual(store.get("running")?.status, .exited)
        XCTAssertEqual(store.get("done")?.status, .exited)
    }

    // MARK: - rename + archive (juancode-211)

    func testSetTitlePersistsAndSyncsFts() {
        let m = meta("r1", title: "original")
        store.insert(m)
        store.update(m, scrollback: Array("haystack needle".utf8))

        store.setTitle("r1", title: "Renamed widget")
        XCTAssertEqual(store.get("r1")?.title, "Renamed widget")
        // Scrollback untouched by a rename.
        XCTAssertEqual(store.getScrollback("r1"), Array("haystack needle".utf8))
        // FTS reflects the new title and still indexes the scrollback.
        XCTAssertEqual(store.search("widget", limit: 10).map(\.meta.id), ["r1"])
        XCTAssertEqual(store.search("needle", limit: 10).map(\.meta.id), ["r1"])
        XCTAssertTrue(store.search("original", limit: 10).isEmpty)
    }

    func testArchivedDefaultsFalseAndRoundTrips() {
        let m = meta("a1")
        store.insert(m)
        XCTAssertEqual(store.get("a1")?.archived, false)

        store.setArchived("a1", archived: true)
        XCTAssertEqual(store.get("a1")?.archived, true)

        store.setArchived("a1", archived: false)
        XCTAssertEqual(store.get("a1")?.archived, false)
    }

    func testArchivedPersistsThroughUpdate() {
        var m = meta("a2")
        m.archived = true
        store.insert(m)
        XCTAssertEqual(store.get("a2")?.archived, true)

        // A normal meta update keeps the flag.
        store.update(m, scrollback: Array("x".utf8))
        XCTAssertEqual(store.get("a2")?.archived, true)
    }

    func testArchivedSurvivesReopen() throws {
        var m = meta("a3")
        m.archived = true
        store.insert(m)
        store = nil

        let reopened = try GRDBStore(path: path)
        XCTAssertEqual(reopened.get("a3")?.archived, true)
    }

    // MARK: - search (FTS5)

    func testSearchMatchesTitleAndScrollback() {
        let a = meta("a", title: "Refactor the parser")
        store.insert(a)
        store.update(a, scrollback: Array("nothing relevant here".utf8))

        let b = meta("b", title: "Unrelated")
        store.insert(b)
        store.update(b, scrollback: Array("the quick brown parser fox".utf8))

        let hits = store.search("parser", limit: 50)
        XCTAssertEqual(Set(hits.map(\.meta.id)), ["a", "b"])
        XCTAssertFalse(hits.first { $0.meta.id == "b" }!.snippet.isEmpty)
    }

    func testSearchPrefixAndAnd() {
        let a = meta("a", title: "deploy pipeline broken")
        store.insert(a)
        store.update(a, scrollback: [])
        // prefix match: "pipe" -> "pipeline"; AND of both tokens
        XCTAssertEqual(store.search("deploy pipe", limit: 10).map(\.meta.id), ["a"])
        XCTAssertTrue(store.search("deploy missing", limit: 10).isEmpty)
    }

    func testSearchBlankReturnsEmpty() {
        store.insert(meta("a", title: "x"))
        XCTAssertTrue(store.search("   ", limit: 10).isEmpty)
    }

    func testToFtsMatchEscapesQuotes() {
        XCTAssertEqual(GRDBStore.toFtsMatch("foo bar"), "\"foo\"* AND \"bar\"*")
        XCTAssertEqual(GRDBStore.toFtsMatch("  spaced   out "), "\"spaced\"* AND \"out\"*")
        XCTAssertEqual(GRDBStore.toFtsMatch("a\"b"), "\"a\"\"b\"*")
        XCTAssertEqual(GRDBStore.toFtsMatch("   "), "")
    }

    func testSearchToleratesStrayOperators() {
        let a = meta("a", title: "AND OR NEAR weirdness")
        store.insert(a)
        store.update(a, scrollback: [])
        // Should not throw / should treat operators as literals.
        XCTAssertEqual(store.search("weirdness", limit: 10).map(\.meta.id), ["a"])
        XCTAssertNoThrow(store.search("\"unbalanced", limit: 10))
    }

    // MARK: - comments

    func testCommentsAddListOrderRemoveClear() {
        let sid = "s1"
        store.insert(meta(sid))
        let c1 = DiffComment(id: "1", sessionId: sid, file: "a", side: .new, line: 2, endLine: 3, body: "two", createdAt: 200)
        let c2 = DiffComment(id: "2", sessionId: sid, file: "b", side: .old, line: 1, endLine: 1, body: "one", createdAt: 100)
        store.addComment(c1)
        store.addComment(c2)
        XCTAssertEqual(store.listComments(sid).map(\.id), ["2", "1"]) // created_at ASC
        XCTAssertEqual(store.listComments(sid).first, c2)

        XCTAssertTrue(store.removeComment(sid, "2"))
        XCTAssertFalse(store.removeComment(sid, "2"))
        XCTAssertFalse(store.removeComment("other", "1"))
        XCTAssertEqual(store.listComments(sid).map(\.id), ["1"])

        XCTAssertEqual(store.clearComments(sid), 1)
        XCTAssertTrue(store.listComments(sid).isEmpty)
    }

    // MARK: - reviews

    func testReviewSaveOverwriteGet() {
        let sid = "s1"
        store.insert(meta(sid))
        XCTAssertNil(store.getReview(sid))

        let r1 = ReviewResult(status: .ok, findings: [
            ReviewFinding(file: "a.ts", side: .new, line: 5, severity: .high, title: "bug", note: "fix it")
        ], summary: "one finding", createdAt: 100)
        store.saveReview(sid, r1)
        XCTAssertEqual(store.getReview(sid), r1)

        let r2 = ReviewResult(status: .empty, findings: [], summary: nil, createdAt: 200)
        store.saveReview(sid, r2)
        XCTAssertEqual(store.getReview(sid), r2)
    }

    // MARK: - persistence across reopen

    func testDataSurvivesReopen() throws {
        let m = meta("persist")
        store.insert(m)
        store.update(m, scrollback: Array("scroll".utf8))
        store = nil

        let reopened = try GRDBStore(path: path)
        XCTAssertEqual(reopened.get("persist")?.id, "persist")
        XCTAssertEqual(reopened.getScrollback("persist"), Array("scroll".utf8))
    }

    // MARK: - per-project retention cap (juancode-477)

    private func metaIn(_ id: String, cwd: String, createdAt: Int) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: cwd, title: id, status: .exited,
            exitCode: 0, createdAt: createdAt, updatedAt: createdAt,
            cliSessionId: nil, skipPermissions: false, worktreePath: nil, usage: nil
        )
    }

    func testEnforceSessionCapKeepsNewestPerProject() {
        // 25 sessions in one project; the 5 oldest should be pruned.
        for i in 0..<25 { store.insert(metaIn("p-\(i)", cwd: "/repo", createdAt: 1000 + i)) }
        let deleted = store.enforceSessionCap(perProject: 20)
        XCTAssertEqual(Set(deleted), Set((0..<5).map { "p-\($0)" }))
        let remaining = store.list().map(\.id)
        XCTAssertEqual(remaining.count, 20)
        XCTAssertFalse(remaining.contains("p-0"))
        XCTAssertTrue(remaining.contains("p-24"))
    }

    func testEnforceSessionCapIsPerProjectAndFoldsWorktrees() {
        // A repo and one of its juancode worktrees share a single cap.
        for i in 0..<15 { store.insert(metaIn("r-\(i)", cwd: "/w/repo", createdAt: i)) }
        for i in 0..<15 { store.insert(metaIn("wt-\(i)", cwd: "/w/repo-worktrees/a", createdAt: 100 + i)) }
        // A second, separate project stays untouched.
        for i in 0..<5 { store.insert(metaIn("o-\(i)", cwd: "/w/other", createdAt: i)) }

        let deleted = store.enforceSessionCap(perProject: 20)
        // 30 sessions fold into /w/repo → 10 oldest pruned; /w/other (5) untouched.
        XCTAssertEqual(deleted.count, 10)
        XCTAssertTrue(deleted.allSatisfy { $0.hasPrefix("r-") })
        XCTAssertEqual(store.list().filter { $0.cwd == "/w/other" }.count, 5)
    }

    func testEnforceSessionCapNeverPrunesKeptIds() {
        for i in 0..<25 { store.insert(metaIn("k-\(i)", cwd: "/repo", createdAt: i)) }
        // Protect an old one that would otherwise be pruned.
        let deleted = store.enforceSessionCap(perProject: 20, keepIds: ["k-0"])
        XCTAssertFalse(deleted.contains("k-0"))
        XCTAssertNotNil(store.get("k-0"))
        // It still occupies a slot in the count, so the survivors shrink by one
        // rather than the cap absorbing the protected id: only 4 of the 5 overflow
        // rows are pruned.
        XCTAssertEqual(Set(deleted), Set(["k-1", "k-2", "k-3", "k-4"]))
    }

    func testEnforceSessionCapDisabledWhenNonPositive() {
        for i in 0..<25 { store.insert(metaIn("z-\(i)", cwd: "/repo", createdAt: i)) }
        XCTAssertEqual(store.enforceSessionCap(perProject: 0), [])
        XCTAssertEqual(store.list().count, 25)
    }

    func testEnforceSessionCapExcludesArchived() {
        // 5 archived + 20 live in one project, cap 20. Archived neither count toward
        // the cap nor get pruned, so nothing is deleted.
        for i in 0..<5 {
            var m = metaIn("a-\(i)", cwd: "/repo", createdAt: i)
            m.archived = true
            store.insert(m)
        }
        for i in 0..<20 { store.insert(metaIn("p-\(i)", cwd: "/repo", createdAt: 100 + i)) }
        let deleted = store.enforceSessionCap(perProject: 20)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(store.list().count, 25)
        // Even the oldest archived survives despite sitting far past the cap.
        XCTAssertNotNil(store.get("a-0"))
    }
}
