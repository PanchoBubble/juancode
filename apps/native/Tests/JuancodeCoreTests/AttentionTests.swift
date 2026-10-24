import Foundation
import Testing
@testable import JuancodeCore

struct AttentionTests {
    private func item(_ id: String, session: String = "s", kind: String = "completion",
                      at: Int = 1, read: Bool = false, resolved: Bool = false) throws -> AttentionItem {
        let body: [String: Any] = ["id": id, "sessionId": session, "kind": kind,
                                  "createdAt": at, "updatedAt": at,
                                  "acknowledged": read, "resolved": resolved]
        return try JSONDecoder().decode(AttentionItem.self, from: JSONSerialization.data(withJSONObject: body))
    }
    @Test func oldestTargetsTheCorrectSessionAndReadStateSurvivesRoundTrip() throws {
        let newer = try item("newer", session: "session-new", at: 3)
        let oldest = try item("oldest", session: "session-old", at: 1)
        let read = try item("read", at: 0, read: true)
        let waiting = try item("waiting", kind: "waiting", at: 2, read: true)
        let resolved = try item("resolved", at: 0, resolved: true)
        let snapshot = [newer, read, oldest, resolved, waiting]
        let decoded = try JSONDecoder().decode([AttentionItem].self, from: JSONEncoder().encode(snapshot))
        let active = AttentionItem.actionable(decoded)
        #expect(active.map(\.id) == ["oldest", "waiting", "newer"])
        #expect(active.first?.sessionId == "session-old")
        #expect(decoded == snapshot)
    }
    @Test func tiesAreStableAndFutureKindsRemainReadable() throws {
        let a = try item("a", kind: "future")
        let z = try item("z")
        #expect(AttentionItem.actionable([z, a]).map(\.id) == ["a", "z"])
        #expect(a.title == "Session needs attention")
    }
}
