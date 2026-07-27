import XCTest
@testable import JuancodeCore

final class SessionDateFormatTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func ms(_ iso: String) -> Int {
        let fmt = ISO8601DateFormatter()
        return Int(fmt.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    func testTodayShowsTimeOfDay() {
        let now = ISO8601DateFormatter().date(from: "2026-07-27T18:00:00Z")!
        let label = SessionDateFormat.compact(
            msSinceEpoch: ms("2026-07-27T14:03:00Z"), now: now, calendar: calendar)
        XCTAssertEqual(label, "14:03")
    }

    func testSameYearShowsDayAndMonth() {
        let now = ISO8601DateFormatter().date(from: "2026-07-27T18:00:00Z")!
        let label = SessionDateFormat.compact(
            msSinceEpoch: ms("2026-03-05T09:00:00Z"), now: now, calendar: calendar)
        XCTAssertEqual(label, "5 Mar")
    }

    func testOlderYearIncludesYear() {
        let now = ISO8601DateFormatter().date(from: "2026-07-27T18:00:00Z")!
        let label = SessionDateFormat.compact(
            msSinceEpoch: ms("2025-12-31T09:00:00Z"), now: now, calendar: calendar)
        XCTAssertEqual(label, "31 Dec 25")
    }
}
