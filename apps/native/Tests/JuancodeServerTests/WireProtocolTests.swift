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

    // ── Dispatch-flavored create (juancode-2kz.1) ────────────────────────────────

    func testDecodesCreateWithDispatchId() throws {
        let json = """
        {"type":"create","provider":"claude","cwd":"/abs/repo","cols":120,"rows":40,
         "initialInput":"do the thing","skipPermissions":true,"isolateWorktree":true,
         "dispatchId":"c0ffee-1"}
        """
        guard case let .create(provider, cwd, cols, rows, initialInput,
                               skipPermissions, isolateWorktree, dispatchId) = try decode(json) else {
            return XCTFail("expected .create")
        }
        XCTAssertEqual(provider, "claude")
        XCTAssertEqual(cwd, "/abs/repo")
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
        XCTAssertEqual(initialInput, "do the thing")
        XCTAssertEqual(skipPermissions, true)
        XCTAssertEqual(isolateWorktree, true)
        XCTAssertEqual(dispatchId, "c0ffee-1")
    }

    func testDecodesCreateWithoutDispatchIdStaysBackCompatible() throws {
        // Ordinary interactive creates (desktop/web clients) carry no dispatchId;
        // it must decode to nil, not fail.
        let json = #"{"type":"create","provider":"codex","cwd":"/p","cols":80,"rows":24}"#
        guard case let .create(provider, cwd, _, _, initialInput, _, _, dispatchId) = try decode(json) else {
            return XCTFail("expected .create")
        }
        XCTAssertEqual(provider, "codex")
        XCTAssertEqual(cwd, "/p")
        XCTAssertNil(initialInput)
        XCTAssertNil(dispatchId)
    }

    // ── Version/capability handshake + graceful degrade (juancode-tgc) ───────────

    func testUnknownTypeDegradesToUnknown() throws {
        // A well-formed frame with an unrecognised `type` decodes to `.unknown`
        // rather than throwing, so the server can ignore it instead of replying
        // with a spurious "Invalid JSON".
        guard case let .unknown(type) = try decode(#"{"type":"bogus"}"#) else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(type, "bogus")
    }

    func testTSOnlyMessageTypeDegradesToUnknown() throws {
        // Types the Node server implements but the embedded native server doesn't
        // (a real case: the web client sends these) must degrade, not error.
        for t in ["subscribeStructured", "steerMessage", "reattachTerminal"] {
            guard case let .unknown(type) = try decode(#"{"type":"\#(t)","sessionId":"s-1"}"#) else {
                return XCTFail("expected .unknown for \(t)")
            }
            XCTAssertEqual(type, t)
        }
    }

    func testMalformedJsonStillThrows() {
        // Genuinely malformed input (missing the `type` discriminator, or not an
        // object) is still a decode failure — only *unknown types* are tolerated.
        XCTAssertThrowsError(try decode(#"{"sessionId":"s-1"}"#))
        XCTAssertThrowsError(try decode(#"[1,2,3]"#))
    }

    func testEncodesServerInfo() throws {
        let msg = ServerMessage.serverInfo(protocolVersion: WireProtocol.version,
                                           capabilities: WireProtocol.capabilities)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "serverInfo")
        XCTAssertEqual(obj?["protocolVersion"] as? Int, WireProtocol.version)
        XCTAssertEqual(obj?["capabilities"] as? [String], WireProtocol.capabilities)
    }

    // ── Input acknowledgement + resend (juancode-1u3) ────────────────────────────

    func testDecodesInputWithSeq() throws {
        let json = #"{"type":"input","sessionId":"s-1","data":"ls\r","seq":7}"#
        guard case let .input(sessionId, data, seq) = try decode(json) else {
            return XCTFail("expected .input")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(data, "ls\r")
        XCTAssertEqual(seq, 7)
    }

    func testDecodesInputWithoutSeqStaysBackCompatible() throws {
        // Older clients omit `seq`; it must decode to nil, not fail (the server
        // then just writes without acking).
        let json = #"{"type":"input","sessionId":"s-1","data":"x"}"#
        guard case let .input(sessionId, data, seq) = try decode(json) else {
            return XCTFail("expected .input")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(data, "x")
        XCTAssertNil(seq)
    }

    func testEncodesInputAck() throws {
        let msg = ServerMessage.inputAck(sessionId: "s-1", seq: 42)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "inputAck")
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        XCTAssertEqual(obj?["seq"] as? Int, 42)
    }

    func testInputAckCapabilityIsAdvertised() {
        // Clients feature-detect the ack via `serverInfo` capabilities.
        XCTAssertTrue(WireProtocol.capabilities.contains("inputAck"))
    }

    // ── Resize acknowledgement + resend (juancode-uz6) ───────────────────────────

    func testDecodesResizeWithSeq() throws {
        let json = #"{"type":"resize","sessionId":"s-1","cols":120,"rows":40,"seq":3}"#
        guard case let .resize(sessionId, cols, rows, seq) = try decode(json) else {
            return XCTFail("expected .resize")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
        XCTAssertEqual(seq, 3)
    }

    func testDecodesResizeWithoutSeqStaysBackCompatible() throws {
        // Older clients omit `seq`; it must decode to nil, not fail (the server
        // then just resizes without acking).
        let json = #"{"type":"resize","sessionId":"s-1","cols":80,"rows":24}"#
        guard case let .resize(sessionId, cols, rows, seq) = try decode(json) else {
            return XCTFail("expected .resize")
        }
        XCTAssertEqual(sessionId, "s-1")
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
        XCTAssertNil(seq)
    }

    func testEncodesResizeAck() throws {
        let msg = ServerMessage.resizeAck(sessionId: "s-1", seq: 9, cols: 100, rows: 30,
                                          applied: false, denied: false)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "resizeAck")
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        XCTAssertEqual(obj?["seq"] as? Int, 9)
        XCTAssertEqual(obj?["cols"] as? Int, 100)
        XCTAssertEqual(obj?["rows"] as? Int, 30)
        XCTAssertEqual(obj?["applied"] as? Bool, false)
        XCTAssertEqual(obj?["denied"] as? Bool, false)
    }

    func testEncodesResizeAckDenied() throws {
        // A resize denied because another client owns the shared grid
        // (juancode-1th.1): the client reads `denied` to stop retrying.
        let msg = ServerMessage.resizeAck(sessionId: "s-1", seq: 9, cols: 100, rows: 30,
                                          applied: false, denied: true)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["applied"] as? Bool, false)
        XCTAssertEqual(obj?["denied"] as? Bool, true)
    }

    func testResizeAckCapabilityIsAdvertised() {
        XCTAssertTrue(WireProtocol.capabilities.contains("resizeAck"))
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

    // ── Rendered-screen stream (juancode-a2h.3) ──────────────────────────────────

    func testDecodesSubscribeAndUnsubscribeScreen() throws {
        guard case let .subscribeScreen(a) = try decode(#"{"type":"subscribeScreen","sessionId":"s-1"}"#) else {
            return XCTFail("expected .subscribeScreen")
        }
        XCTAssertEqual(a, "s-1")
        guard case let .unsubscribeScreen(b) = try decode(#"{"type":"unsubscribeScreen","sessionId":"s-2"}"#) else {
            return XCTFail("expected .unsubscribeScreen")
        }
        XCTAssertEqual(b, "s-2")
    }

    func testEncodesScreenFrame() throws {
        let msg = ServerMessage.screen(
            sessionId: "s-1", reset: true, cols: 80, rows: 24,
            cursorX: 3, cursorY: 5, cursorVisible: true, alt: false,
            lines: [ScreenRowWire(row: 0, segs: [
                ScreenSegmentWire(text: "hi", fg: .ansi(2), bg: .default, style: [.bold]),
                ScreenSegmentWire(text: "!", fg: .trueColor(r: 255, g: 0, b: 16), bg: .defaultInverted, style: []),
            ])])
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "screen")
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        XCTAssertEqual(obj?["reset"] as? Bool, true)
        XCTAssertEqual(obj?["cols"] as? Int, 80)
        XCTAssertEqual(obj?["rows"] as? Int, 24)
        XCTAssertEqual(obj?["cursorX"] as? Int, 3)
        XCTAssertEqual(obj?["cursorY"] as? Int, 5)
        XCTAssertEqual(obj?["cursorVisible"] as? Bool, true)
        XCTAssertEqual(obj?["alt"] as? Bool, false)
        let lines = obj?["lines"] as? [[String: Any]]
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?[0]["row"] as? Int, 0)
        let segs = lines?[0]["segs"] as? [[String: Any]]
        XCTAssertEqual(segs?.count, 2)
        // ANSI-256 encodes as a number; the default fg/bg and an empty style are
        // omitted; truecolor is "#rrggbb"; default-inverted is "inv".
        XCTAssertEqual(segs?[0]["text"] as? String, "hi")
        XCTAssertEqual(segs?[0]["fg"] as? Int, 2)
        XCTAssertNil(segs?[0]["bg"])
        XCTAssertEqual(segs?[0]["st"] as? Int, 1)
        XCTAssertEqual(segs?[1]["fg"] as? String, "#ff0010")
        XCTAssertEqual(segs?[1]["bg"] as? String, "inv")
        XCTAssertNil(segs?[1]["st"])
    }

    func testScreenCapabilityIsAdvertised() {
        // A client sends `subscribeScreen` only after seeing this in `serverInfo`;
        // connections that never opt in keep today's byte stream unchanged.
        XCTAssertTrue(WireProtocol.capabilities.contains("screen"))
    }

    // ── Settle-edge change rollup on `activity` ──────────────────────────────────

    func testEncodesActivityWithChanges() throws {
        let msg = ServerMessage.activity(
            sessionId: "s-1", state: .idle, notify: true,
            changes: ChangeStat(files: 3, additions: 120, deletions: 44, signature: "sig"),
            dispatchId: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "activity")
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        XCTAssertEqual(obj?["state"] as? String, "idle")
        XCTAssertEqual(obj?["notify"] as? Bool, true)
        let changes = obj?["changes"] as? [String: Any]
        XCTAssertEqual(changes?["files"] as? Int, 3)
        XCTAssertEqual(changes?["additions"] as? Int, 120)
        XCTAssertEqual(changes?["deletions"] as? Int, 44)
        // The signature is a desktop-local debounce key — never on the wire.
        XCTAssertNil(changes?["signature"])
    }

    func testEncodesActivityOmitsChangesWhenNil() throws {
        let msg = ServerMessage.activity(sessionId: "s-1", state: .busy, notify: false,
                                         changes: nil, dispatchId: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "activity")
        XCTAssertEqual(obj?["state"] as? String, "busy")
        // Omitted, not null — old clients (and the TS mirror) just never see the key.
        XCTAssertNil(obj?["changes"])
    }

    // ── Dispatch correlation on `activity` ───────────────────────────────────────

    func testEncodesActivityWithDispatchId() throws {
        let msg = ServerMessage.activity(sessionId: "s-1", state: .waitingInput, notify: true,
                                         changes: nil, dispatchId: "d-42")
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "activity")
        XCTAssertEqual(obj?["dispatchId"] as? String, "d-42")
    }

    func testEncodesActivityOmitsDispatchIdWhenNil() throws {
        // Interactive sessions have no dispatch; the key must be absent, not null,
        // so old clients (and the TS mirror's lenient parse) ignore it.
        let msg = ServerMessage.activity(sessionId: "s-1", state: .idle, notify: true,
                                         changes: nil, dispatchId: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(msg.jsonString().utf8)) as? [String: Any]
        XCTAssertNil(obj?["dispatchId"])
    }

    func testSessionMetaRoundTripsDispatchId() throws {
        // The `created`/`attached` payloads and /api/sessions all serialize the full
        // SessionMeta, so the correlation must survive an encode/decode round trip —
        // and a payload predating the field must decode to nil.
        let meta = SessionMeta(
            id: "s-1", provider: .claude, cwd: "/p", title: "t", status: .running,
            exitCode: nil, createdAt: 1, updatedAt: 2, cliSessionId: nil,
            skipPermissions: true, worktreePath: nil, usage: nil, dispatchId: "d-42")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: data)
        XCTAssertEqual(decoded.dispatchId, "d-42")
        XCTAssertEqual(decoded, meta)

        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "dispatchId")
        let old = try JSONDecoder().decode(
            SessionMeta.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.dispatchId)
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
