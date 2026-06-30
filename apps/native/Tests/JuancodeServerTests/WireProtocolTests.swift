import XCTest
import JuancodeCore
@testable import JuancodeServer

/// Decode coverage for the WS wire protocol (juancode-iqi adds `adoptExternal`).
/// Keeps the flat-JSON shape in sync with the two `protocol.ts` files.
final class WireProtocolTests: XCTestCase {
    private func decode(_ json: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
    }

    func testDecodesAdoptExternal() throws {
        let json = """
        {"type":"adoptExternal","provider":"claude","cliSessionId":"conv-7",
         "cwd":"/Users/me/project","startMs":1700000000000,"cols":120,"rows":40}
        """
        guard case let .adoptExternal(provider, cliSessionId, cwd, startMs, cols, rows) = try decode(json) else {
            return XCTFail("expected .adoptExternal")
        }
        XCTAssertEqual(provider, "claude")
        XCTAssertEqual(cliSessionId, "conv-7")
        XCTAssertEqual(cwd, "/Users/me/project")
        XCTAssertEqual(startMs, 1_700_000_000_000)
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
    }

    func testUnknownTypeStillThrows() {
        XCTAssertThrowsError(try decode(#"{"type":"bogus"}"#))
    }

    // ── Per-session message queue (oracle-cj3 / juancode-r82) ────────────────────

    func testDecodesQueueMessage() throws {
        let json = #"{"type":"queueMessage","sessionId":"s-1","text":"run the tests"}"#
        guard case let .queueMessage(sessionId, text) = try decode(json) else {
            return XCTFail("expected .queueMessage")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(text, "run the tests")
    }

    func testDecodesDequeueMessage() throws {
        let json = #"{"type":"dequeueMessage","sessionId":"s-1","messageId":"m-9"}"#
        guard case let .dequeueMessage(sessionId, messageId) = try decode(json) else {
            return XCTFail("expected .dequeueMessage")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(messageId, "m-9")
    }

    func testDecodesSubscribeAndUnsubscribeQueue() throws {
        guard case let .subscribeQueue(a) = try decode(#"{"type":"subscribeQueue","sessionId":"s-1"}"#) else {
            return XCTFail("expected .subscribeQueue")
        }
        XCTAssertEqual(a, "s-1")
        guard case let .unsubscribeQueue(b) = try decode(#"{"type":"unsubscribeQueue","sessionId":"s-2"}"#) else {
            return XCTFail("expected .unsubscribeQueue")
        }
        XCTAssertEqual(b, "s-2")
    }

    func testEncodesQueueServerMessage() throws {
        let msg = ServerMessage.queue(
            sessionId: "s-1",
            items: [QueuedMessage(id: "m-1", text: "first", createdAt: 100),
                    QueuedMessage(id: "m-2", text: "second", createdAt: 200)])
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "queue")
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        let items = obj?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0]["id"] as? String, "m-1")
        XCTAssertEqual(items?[0]["text"] as? String, "first")
        XCTAssertEqual(items?[0]["createdAt"] as? Int, 100)
        XCTAssertEqual(items?[1]["text"] as? String, "second")
    }
}
