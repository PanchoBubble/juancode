import Foundation
import Testing
@testable import JuancodeCore

/// The staleness policy behind the GitHub view's selected-PR refresh
/// (juancode-zp29): first load, the focused/background cadences, the burst floor,
/// and the poller short-circuit.
@Suite struct PrFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func due(_ ageSeconds: TimeInterval?, focused: Bool = true,
                     poller: Bool = false) -> Bool {
        prDetailRefreshDue(lastFetched: ageSeconds.map { now.addingTimeInterval(-$0) },
                           now: now, focused: focused, pollerActivity: poller)
    }

    @Test func neverFetchedIsAlwaysDue() {
        #expect(due(nil))
        #expect(due(nil, focused: false))
    }

    @Test func focusedRefreshesOnTheShortCadence() {
        #expect(!due(prDetailRefreshInterval - 1))
        #expect(due(prDetailRefreshInterval))
        #expect(due(prDetailRefreshInterval + 60))
    }

    @Test func backgroundBacksOff() {
        // Old enough for the focused cadence, not for the background one.
        #expect(!due(prDetailRefreshInterval + 1, focused: false))
        #expect(!due(prDetailBackgroundRefreshInterval - 1, focused: false))
        #expect(due(prDetailBackgroundRefreshInterval, focused: false))
    }

    @Test func pollerActivityRefreshesAheadOfTheCadence() {
        #expect(!due(10))
        #expect(due(10, poller: true))
        // Still worth refetching in the background — the PR is known to have moved.
        #expect(due(10, focused: false, poller: true))
    }

    @Test func floorSwallowsABurstOfPollerSignals() {
        #expect(!due(prDetailRefreshFloor - 1, poller: true))
        #expect(due(prDetailRefreshFloor, poller: true))
    }

    @Test func aBackwardsClockRefetchesInsteadOfStalling() {
        #expect(due(-3600))
        #expect(due(-3600, focused: false))
    }
}
