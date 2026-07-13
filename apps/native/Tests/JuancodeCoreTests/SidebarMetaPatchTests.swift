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

    // MARK: - invisible-delta damping (juancode-idq)

    private func usage(_ total: Int) -> SessionUsage {
        SessionUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                     cacheWriteTokens: 0, totalTokens: total, costUsd: nil)
    }

    @Test func subLabelUsageDeltaIsNoChange() {
        // 12_400 and 12_449 both render "12.4k tok" — the poll's raw delta is
        // invisible, so the row (and every sessions-array reader) must not re-render.
        let sessions = [meta("a", usage: usage(12_400))]
        var next = meta("a", usage: usage(12_449))
        next.updatedAt = 999 // the poll's persist also bumps updatedAt
        #expect(metaPatchOutcome(for: next, in: sessions) == .noChange)
    }

    @Test func labelCrossingUsageDeltaPatches() {
        // 9_900 → 12_400 flips the badge "9.9k tok" → "12k tok": visible, patch.
        let sessions = [meta("a", usage: usage(9_900))]
        #expect(metaPatchOutcome(for: meta("a", usage: usage(12_400)), in: sessions)
                == .patch(index: 0))
    }

    @Test func updatedAtOnlyBumpIsNoChange() {
        let sessions = [meta("a", usage: usage(12_400))]
        var next = meta("a", usage: usage(12_400))
        next.updatedAt = 999
        // Nothing rendered changed; the published array's updatedAt is a laggy
        // display cache by design (live meta / the store stay precise).
        #expect(metaPatchOutcome(for: next, in: sessions) == .noChange)
    }

    @Test func nonUsageChangeStillPatchesEvenWithSubLabelUsageDelta() {
        let sessions = [meta("a", usage: usage(12_400))]
        var next = meta("a", title: "renamed", usage: usage(12_449))
        next.updatedAt = 999
        #expect(metaPatchOutcome(for: next, in: sessions) == .patch(index: 0))
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
