import Foundation
import Testing
import JuancodeCore
@testable import JuancodeServer

/// The session-handoff frames the sidecar sends (juancode-u5q, closeHandoff juancode-8oa5.2),
/// in the shapes `native-events.ts` writes them. Swift Testing so it runs without XCTest.
@Suite struct HandoffFrameDecodeTests {
    private func decode(_ json: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
    }

    @Test func decodesTheHandoffFrames() throws {
        guard case let .sleepSession(id) = try decode(#"{"type":"sleepSession","sessionId":"s-1"}"#)
        else { Issue.record("expected .sleepSession"); return }
        #expect(id == "s-1")

        guard case let .createHandoff(handoff, requestId) = try decode(#"""
            {"type":"createHandoff","requestId":"handoff-1","handoff":{"id":"h1","chainSlug":"c",
             "source":{"kind":"session","sessionId":"old"},
             "target":{"kind":"session","sessionId":"new"},"summary":"the note"}}
            """#)
        else { Issue.record("expected .createHandoff"); return }
        #expect(requestId == "handoff-1")
        #expect(handoff.source == .session("old"))
        #expect(handoff.target == .session("new"))
        #expect(handoff.summary == "the note")
        #expect(handoff.state == .pending)

        guard case let .closeHandoff(id, reason, closeRequest) = try decode(#"""
            {"type":"closeHandoff","requestId":"handoff-2","handoffId":"h1","closureReason":"Option B"}
            """#)
        else { Issue.record("expected .closeHandoff"); return }
        #expect(id == "h1")
        #expect(reason == "Option B")
        #expect(closeRequest == "handoff-2")
    }
}
