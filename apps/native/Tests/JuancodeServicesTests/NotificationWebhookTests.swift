import XCTest
@testable import JuancodeServices

/// Unit tests for the notification webhook payload builder (juancode-xac). Pure —
/// no network; the POST itself lives in AppModel and isn't exercised here.
final class NotificationWebhookTests: XCTestCase {
    private func decode(_ data: Data) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    func testTextPerEvent() {
        XCTAssertEqual(notificationText(event: .waitingInput, title: "Fix CI"), "⏳ Fix CI needs your input")
        XCTAssertEqual(notificationText(event: .turnEnd, title: "Fix CI"), "✅ Fix CI finished a turn")
    }

    func testEmptyTitleFallsBack() {
        XCTAssertEqual(notificationText(event: .turnEnd, title: ""), "✅ A session finished a turn")
    }

    func testBodyCarriesSlackTextAndStructuredFields() {
        let obj = decode(webhookBody(event: .waitingInput, title: "Fix CI",
                                     sessionId: "s-1", cwd: "/Users/me/api"))
        XCTAssertEqual(obj["text"], "⏳ Fix CI needs your input") // Slack reads this
        XCTAssertEqual(obj["event"], "waiting_input")             // structured for generic consumers
        XCTAssertEqual(obj["title"], "Fix CI")
        XCTAssertEqual(obj["sessionId"], "s-1")
        XCTAssertEqual(obj["cwd"], "/Users/me/api")
    }

    func testBodyIsValidJson() {
        let data = webhookBody(event: .turnEnd, title: "x", sessionId: "s", cwd: "/c")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
