import XCTest
import JuancodeCore
@testable import JuancodeDesktop

/// Unit tests for the recurring-task scheduler math (juancode-dgp): which tasks are
/// due and when each next fires. Pure — no clock, no pty.
final class RecurringTaskTests: XCTestCase {
    private func task(_ id: String = "t", interval: Int = 60, enabled: Bool = true,
                      nextFireAt: Int) -> RecurringTask {
        RecurringTask(id: id, title: id, cwd: "/repo", provider: .claude, prompt: "go",
                      intervalSeconds: interval, enabled: enabled, createdAt: 0, nextFireAt: nextFireAt)
    }

    func testIntervalMsHasASaneFloor() {
        XCTAssertEqual(recurringIntervalMs(60), 60_000)
        XCTAssertEqual(recurringIntervalMs(0), 1_000)   // never zero
        XCTAssertEqual(recurringIntervalMs(-5), 1_000)  // never negative
    }

    func testInitialFireIsOneIntervalOut() {
        XCTAssertEqual(initialFireTime(createdAt: 10_000, intervalSeconds: 60), 10_000 + 60_000)
    }

    func testNextFireSteppedFromFiredAt() {
        // Fired on time: next is exactly one interval later.
        XCTAssertEqual(nextRecurringFireTime(firedAt: 100_000, intervalSeconds: 60, now: 100_000),
                       100_000 + 60_000)
    }

    func testNextFireSkipsMissedSlotsAfterALongSleep() {
        // Fired at t=0, interval 60s, but we only woke at t=200_000 (3.33 intervals later).
        // The next fire must be strictly in the future, not a backlog of missed slots.
        let next = nextRecurringFireTime(firedAt: 0, intervalSeconds: 60, now: 200_000)
        XCTAssertGreaterThan(next, 200_000)
        XCTAssertEqual(next, 240_000)            // first 60s boundary after now
        XCTAssertEqual((next - 0) % 60_000, 0)   // still aligned to the interval grid
    }

    func testDueFiltersOnEnabledAndTime() {
        let now = 1_000_000
        let due = task("due", nextFireAt: now - 1)
        let notYet = task("future", nextFireAt: now + 60_000)
        let paused = task("paused", enabled: false, nextFireAt: now - 10_000)
        let exactlyNow = task("now", nextFireAt: now)
        let result = dueRecurringTasks([due, notYet, paused, exactlyNow], now: now).map(\.id)
        XCTAssertEqual(Set(result), ["due", "now"])  // <= now and enabled
    }

    func testRecurringTaskRoundTripsThroughCodable() throws {
        let t = task("rt", nextFireAt: 123)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(RecurringTask.self, from: data)
        XCTAssertEqual(back, t)
    }
}
