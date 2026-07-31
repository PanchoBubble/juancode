import Testing
@testable import JuancodeCore

/// Back/forward session history behind the mouse side buttons and ⌘[ / ⌘].
@Suite struct NavHistoryTests {
    /// Drives a history the way the app model does: record the id being left, then
    /// walk back/forward from the current one.
    private struct Nav {
        var history = NavHistory(cap: 4)
        var current: String?
        var alive: Set<String> = ["a", "b", "c", "d", "e", "f"]

        mutating func visit(_ id: String) {
            history.record(leaving: current)
            current = id
        }

        mutating func back() {
            if let target = history.goBack(from: current, exists: { alive.contains($0) }) {
                current = target
            }
        }

        mutating func forward() {
            if let target = history.goForward(from: current, exists: { alive.contains($0) }) {
                current = target
            }
        }
    }

    @Test func backWalksToThePreviouslyViewedSession() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.back()
        #expect(nav.current == "a")
    }

    @Test func forwardReturnsToWhereBackCameFrom() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("c")
        nav.back()
        nav.back()
        #expect(nav.current == "a")
        nav.forward()
        #expect(nav.current == "b")
        nav.forward()
        #expect(nav.current == "c")
        #expect(!nav.history.canGoForward)
    }

    @Test func backAtTheStartOfHistoryIsANoOp() {
        var nav = Nav()
        nav.visit("a")
        nav.back()
        #expect(nav.current == "a")
        nav.forward()
        #expect(nav.current == "a")
    }

    @Test func aFreshJumpAfterBackDiscardsTheForwardStack() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("c")
        nav.back()          // at b, forward holds c
        nav.visit("d")      // new branch
        #expect(!nav.history.canGoForward)
        nav.back()
        #expect(nav.current == "b")
    }

    @Test func reselectingTheSameSessionDoesNotStackHistory() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("b")
        nav.visit("b")
        nav.back()
        #expect(nav.current == "a")
        #expect(!nav.history.canGoBack)
    }

    @Test func deletedSessionsAreSkippedNotLandedOn() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("c")
        nav.alive.remove("b")
        nav.back()
        #expect(nav.current == "a")
    }

    @Test func backIsANoOpWhenEveryEntryBehindIsGone() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.alive.remove("a")
        nav.back()
        #expect(nav.current == "b")
        #expect(!nav.history.canGoBack)
    }

    @Test func historyIsCappedOldestFirst() {
        var nav = Nav()  // cap 4
        for id in ["a", "b", "c", "d", "e", "f"] { nav.visit(id) }
        // Five moves recorded, only the last four kept: b…e, so "a" is unreachable.
        #expect(nav.history.back == ["b", "c", "d", "e"])
        for _ in 0..<10 { nav.back() }
        #expect(nav.current == "b")
    }

    @Test func pruneDropsDeadEntriesFromBothStacks() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("c")
        nav.back()  // at b, forward = [c]
        nav.history.prune(keeping: ["b"])
        #expect(!nav.history.canGoBack)
        #expect(!nav.history.canGoForward)
    }

    @Test func pruneCollapsesEntriesLeftAdjacentByADeletion() {
        var nav = Nav()
        nav.visit("a")
        nav.visit("b")
        nav.visit("a")
        nav.visit("c")
        // back == [a, b, a]; losing b would otherwise leave a duplicated "a" to
        // click past twice.
        nav.history.prune(keeping: ["a", "c"])
        #expect(nav.history.back == ["a"])
    }
}
