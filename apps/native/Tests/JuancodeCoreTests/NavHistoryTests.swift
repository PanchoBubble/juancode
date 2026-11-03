import Testing
@testable import JuancodeCore

@Suite struct NavHistoryTests {
    private enum Destination: Equatable {
        case session(String)
        case review(session: String, pr: String?)
        case github(String)
        case beads(project: String, ticket: String?)
    }

    @Test func reviewsAndOtherViewsRoundTripWithoutChangingSession() {
        let visits: [Destination] = [
            .session("a"), .github("pr-1"), .review(session: "a", pr: "pr-1"),
            .beads(project: "/repo", ticket: "issue-1"), .session("b")
        ]
        var history = NavigationHistory<Destination>()
        for visit in visits.dropLast() { history.record(leaving: visit) }
        var current = visits.last!
        for expected in visits.dropLast().reversed() {
            current = history.goBack(from: current, exists: { _ in true })!
            #expect(current == expected)
        }
        #expect(!history.canGoBack)
        for expected in visits.dropFirst() {
            current = history.goForward(from: current, exists: { _ in true })!
            #expect(current == expected)
        }
        #expect(!history.canGoForward)
    }

    @Test func switchingBetweenReviewsPreservesTheirTargets() {
        var history = NavigationHistory<Destination>()
        let first = Destination.review(session: "a", pr: "pr-1")
        let second = Destination.review(session: "a", pr: "pr-2")
        history.record(leaving: first)
        #expect(history.goBack(from: second, exists: { _ in true }) == first)
        #expect(history.goForward(from: first, exists: { _ in true }) == second)
    }

    @Test func freshNavigationDiscardsForwardEvenWithDuplicatePreviousEntry() {
        var history = NavHistory()
        history.record(leaving: "a")
        history.record(leaving: "b")
        history.record(leaving: "a")
        #expect(history.goBack(from: "c", exists: { _ in true }) == "a")
        // A fresh jump leaving b matches the latest entry behind us. It still
        // invalidates the old forward branch, rather than resurrecting c.
        history.record(leaving: "b")
        #expect(!history.canGoForward)
        #expect(history.back == ["a", "b"])
    }

    @Test func deletedDestinationsAreSkippedInBothDirections() {
        var history = NavHistory()
        history.record(leaving: "a")
        history.record(leaving: "deleted")
        #expect(history.goBack(from: "b", exists: { $0 != "deleted" }) == "a")
        #expect(history.goForward(from: "a", exists: { $0 != "b" }) == nil)
        #expect(!history.canGoForward)
    }

    @Test func pruningRemovesEveryViewOfADeletedSession() {
        var history = NavigationHistory<Destination>()
        history.record(leaving: .session("a"))
        history.record(leaving: .review(session: "a", pr: nil))
        history.record(leaving: .session("b"))
        history.prune { destination in
            switch destination {
            case .session("a"), .review(session: "a", pr: _): return false
            default: return true
            }
        }
        #expect(history.back == [.session("b")])
    }

    @Test func exhaustedBackDoesNotCreateForwardEntries() {
        var history = NavHistory()
        history.record(leaving: "gone")
        #expect(history.goBack(from: "current", exists: { _ in false }) == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func boundedHistoryKeepsTheMostRecentVisits() {
        var history = NavHistory(cap: 2)
        for id in ["a", "b", "c"] { history.record(leaving: id) }
        #expect(history.back == ["b", "c"])
        #expect(history.goBack(from: "d", exists: { _ in true }) == "c")
        #expect(history.goBack(from: "c", exists: { _ in true }) == "b")
        #expect(history.forward == ["d", "c"])
    }
}
