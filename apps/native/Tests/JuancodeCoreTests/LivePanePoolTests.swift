import Testing
@testable import JuancodeCore

/// Keep-alive terminal pane pool (juancode-073): MRU ordering, LRU eviction at
/// the cap, pruning of dead/swapped sessions, and refresh-token re-keying.
@Suite struct LivePanePoolTests {
    final class FakeSession {}

    /// A registry stand-in: id → live session object (nil = exited).
    private func makePool(cap: Int = 3) -> LivePanePool<FakeSession> {
        LivePanePool<FakeSession>(cap: cap)
    }

    @Test func firstVisitMountsAtFront() {
        var pool = makePool()
        let a = FakeSession()
        pool.noteVisible("a", refresh: 0) { _ in a }
        #expect(pool.entries.map(\.sessionId) == ["a"])
        #expect(pool.entries[0].session === a)
    }

    @Test func revisitMovesToFrontWithoutRekeying() {
        var pool = makePool()
        let live = ["a": FakeSession(), "b": FakeSession()]
        pool.noteVisible("a", refresh: 0) { live[$0] }
        let originalId = pool.entries[0].id
        pool.noteVisible("b", refresh: 0) { live[$0] }
        // Returning with a NEWER refresh token must not recreate the pane — the
        // token is only adopted at (re)creation, else every Refresh of another
        // session would tear down this one's mounted surface.
        pool.noteVisible("a", refresh: 7) { live[$0] }
        #expect(pool.entries.map(\.sessionId) == ["a", "b"])
        #expect(pool.entries[0].id == originalId)
    }

    @Test func capEvictsLeastRecentlyViewed() {
        var pool = makePool(cap: 2)
        let live = ["a": FakeSession(), "b": FakeSession(), "c": FakeSession()]
        pool.noteVisible("a", refresh: 0) { live[$0] }
        pool.noteVisible("b", refresh: 0) { live[$0] }
        pool.noteVisible("c", refresh: 0) { live[$0] }
        #expect(pool.entries.map(\.sessionId) == ["c", "b"])
    }

    @Test func deadSessionIsNotMounted() {
        var pool = makePool()
        pool.noteVisible("gone", refresh: 0) { _ in nil }
        #expect(pool.entries.isEmpty)
    }

    @Test func pruneDropsExitedSessions() {
        var pool = makePool()
        var live: [String: FakeSession] = ["a": FakeSession(), "b": FakeSession()]
        pool.noteVisible("a", refresh: 0) { live[$0] }
        pool.noteVisible("b", refresh: 0) { live[$0] }
        live["a"] = nil // session exited / was killed while pooled hidden
        pool.prune { live[$0] }
        #expect(pool.entries.map(\.sessionId) == ["b"])
    }

    @Test func swappedSessionObjectIsRekeyed() {
        var pool = makePool()
        var live: [String: FakeSession] = ["a": FakeSession()]
        pool.noteVisible("a", refresh: 0) { live[$0] }
        let oldId = pool.entries[0].id
        // Permissions flip: a NEW Session object behind the same juancode id. The
        // pooled pane subscribes to the old pty stream, so the entry must be
        // re-keyed (new identity → fresh mount), never reused as-is.
        live["a"] = FakeSession()
        pool.noteVisible("a", refresh: 3) { live[$0] }
        #expect(pool.entries.count == 1)
        #expect(pool.entries[0].id != oldId)
        #expect(pool.entries[0].session === live["a"])
        #expect(pool.entries[0].refresh == 3)
    }

    @Test func pruneDropsSwappedSessionEvenWhileHidden() {
        var pool = makePool()
        var live: [String: FakeSession] = ["a": FakeSession(), "b": FakeSession()]
        pool.noteVisible("a", refresh: 0) { live[$0] }
        pool.noteVisible("b", refresh: 0) { live[$0] }
        live["a"] = FakeSession() // swapped behind the same id while off-screen
        pool.prune { live[$0] }
        #expect(pool.entries.map(\.sessionId) == ["b"])
    }

    @Test func bumpRefreshRekeysOnlyThatEntry() {
        var pool = makePool()
        let live = ["a": FakeSession(), "b": FakeSession()]
        pool.noteVisible("b", refresh: 0) { live[$0] }
        pool.noteVisible("a", refresh: 0) { live[$0] }
        let bId = pool.entries.first { $0.sessionId == "b" }!.id
        pool.bumpRefresh("a", to: 1)
        #expect(pool.entries.first { $0.sessionId == "a" }!.refresh == 1)
        #expect(pool.entries.first { $0.sessionId == "b" }!.id == bId)
    }

    @Test func capIsAtLeastOne() {
        var pool = LivePanePool<FakeSession>(cap: 0)
        let a = FakeSession()
        pool.noteVisible("a", refresh: 0) { _ in a }
        #expect(pool.entries.count == 1)
    }
}
