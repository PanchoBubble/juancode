import Testing
@testable import JuancodeCore

/// The sidebar's meta-change dispatch (juancode-5qw.8): the per-session title/usage
/// poll patches the one changed row in place, and only an unseen id falls back to a
/// full `store.list()` rebuild (create/exit/adopt).
@Suite struct SidebarMetaPatchTests {
    private func meta(_ id: String, title: String = "t", createdAt: Int = 0,
                      usage: SessionUsage? = nil) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/w", title: title, status: .running,
                    exitCode: nil, createdAt: createdAt, updatedAt: createdAt,
                    cliSessionId: nil, skipPermissions: true, worktreePath: nil, usage: usage)
    }

    @Test func metaOnlyChangePatchesInPlace() {
        let sessions = [meta("a", createdAt: 2), meta("b", createdAt: 1)]
        // A title/usage poll landing for a session we already hold patches its row.
        let outcome = metaPatchOutcome(for: meta("b", title: "renamed", createdAt: 1), in: sessions)
        #expect(outcome == .patch(index: 1))
    }

    @Test func unchangedMetaIsNoChange() {
        let sessions = [meta("a"), meta("b")]
        // A poll that produced no actual delta must not even re-render the row.
        #expect(metaPatchOutcome(for: meta("a"), in: sessions) == .noChange)
    }

    @Test func unknownIdFallsBackToFullRefresh() {
        let sessions = [meta("a"), meta("b")]
        // A session not in our list yet (an unseen create/adopt) needs a full rebuild.
        #expect(metaPatchOutcome(for: meta("c"), in: sessions) == .fullRefresh)
    }

    // MARK: - store.list() call counting

    /// Counts `list()` calls so a test can assert a patch avoids the DB round-trip.
    private final class SpyStore {
        private(set) var listCount = 0
        var rows: [SessionMeta] = []
        func list() -> [SessionMeta] { listCount += 1; return rows }
    }

    /// Mirrors `AppModel.applyMetaPatch` + `refresh()`: patch in place, or rebuild
    /// from the store on a full refresh.
    private func apply(_ meta: SessionMeta, to sessions: inout [SessionMeta], store: SpyStore) {
        switch metaPatchOutcome(for: meta, in: sessions) {
        case .patch(let i): sessions[i] = meta
        case .noChange: break
        case .fullRefresh: sessions = store.list()
        }
    }

    @Test func patchDoesNotHitTheStore() {
        let store = SpyStore()
        var sessions = [meta("a", createdAt: 2), meta("b", createdAt: 1)]
        store.rows = sessions
        apply(meta("b", title: "renamed", createdAt: 1), to: &sessions, store: store)
        // The row is patched in place with no store round-trip.
        #expect(store.listCount == 0)
        #expect(sessions[1].title == "renamed")
        #expect(sessions.map(\.id) == ["a", "b"]) // order preserved
    }

    @Test func createStillDoesAFullRefresh() {
        let store = SpyStore()
        var sessions = [meta("a", createdAt: 2), meta("b", createdAt: 1)]
        let created = meta("c", createdAt: 3)
        store.rows = [created] + sessions
        apply(created, to: &sessions, store: store)
        // A new (unseen) session rebuilds from the store exactly once.
        #expect(store.listCount == 1)
        #expect(sessions.contains { $0.id == "c" })
    }
}
