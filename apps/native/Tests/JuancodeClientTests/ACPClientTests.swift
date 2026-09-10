import XCTest
import JuancodeCore
@testable import JuancodeClient

/// The ACP transport (juancode-6582), asserted against frames that were recorded off
/// the real `opencode acp` binary rather than invented for the test.
///
/// The end-to-end case drives a stand-in agent that is a real child process speaking
/// real newline-framed JSON-RPC on its own stdio — the same choice the daemon tests
/// make with a stand-in server over a real socket. A mocked transport would assert
/// that our decoder matches our encoder and prove nothing about the framing, which is
/// the part that silently does not work if you reach for LSP's `Content-Length`.
final class ACPClientTests: XCTestCase {

    // MARK: - Folding a turn onto the seam

    /// The measured shape: 290 characters of reasoning arrived as 21 chunks. The seam
    /// must see one thought, and the transcript must hold one readable block.
    func testChunkRunCollapsesToOneThinkingEvent() {
        let stream = ACPSeamStream()
        let words = ["The", " user asks a", " r", "iddle", " about", " sheep."]
        var kinds: [StructuredEventKind] = []
        for word in words {
            kinds += stream.ingest(.agentThought(messageId: "msg_1", text: word)).kinds
        }

        XCTAssertEqual(kinds, [.thinking], "a run of chunks is one thought, not one per chunk")
        XCTAssertEqual(stream.text(of: .thinking), "The user asks a riddle about sheep.")
        XCTAssertEqual(stream.blocks.count, 1)
    }

    /// A new `messageId` is a new block even for the same kind, so two separate
    /// thoughts in one turn do not run together.
    func testNewMessageIdStartsANewRun() {
        let stream = ACPSeamStream()
        _ = stream.ingest(.agentThought(messageId: "msg_1", text: "first"))
        let second = stream.ingest(.agentThought(messageId: "msg_2", text: "second"))

        XCTAssertEqual(second.kinds, [.thinking])
        XCTAssertEqual(stream.blocks.count, 2)
        XCTAssertEqual(stream.text(of: .thinking), "first\nsecond")
    }

    /// An empty chunk neither opens a block nor pulses the detector.
    func testEmptyChunkIsNotAnEvent() {
        let stream = ACPSeamStream()
        XCTAssertEqual(stream.ingest(.agentThought(messageId: "msg_1", text: "")).kinds, [])
        XCTAssertTrue(stream.blocks.isEmpty)
    }

    /// The measured repetition: one call reported `in_progress` three times before
    /// completing. The seam must open it once and resolve it once, or the detector is
    /// told a call it is holding busy on finished several times.
    func testRepeatedToolUpdatesOpenAndResolveExactlyOnce() {
        let stream = ACPSeamStream()
        let id = "call_8c7b446e7e0f4b92bee8ef95"

        let opened = stream.ingest(.toolCall(ACPToolCall(id: id, title: "bash", kind: "execute")))
        XCTAssertEqual(opened.kinds, [.toolUse])
        XCTAssertEqual(opened.openedToolUseIds, [id])

        for _ in 0..<3 {
            let progress = stream.ingest(.toolCallUpdate(
                ACPToolCall(id: id, title: "echo hello-from-acp", kind: "execute", status: .inProgress)))
            XCTAssertEqual(progress.kinds, [], "an in-flight update is not a new seam event")
        }

        let done = stream.ingest(.toolCallUpdate(
            ACPToolCall(id: id, status: .completed, output: "hello-from-acp\n")))
        XCTAssertEqual(done.kinds, [.toolResult])
        XCTAssertEqual(done.resolvedToolUseIds, [id])

        let again = stream.ingest(.toolCallUpdate(ACPToolCall(id: id, status: .completed)))
        XCTAssertEqual(again.kinds, [], "a repeated completion resolves nothing new")

        XCTAssertEqual(stream.blocks.count, 1, "one call is one block however many updates it took")
        guard case let .tool(call) = stream.blocks[0] else { return XCTFail("expected a tool block") }
        XCTAssertEqual(call.title, "echo hello-from-acp", "a later update must not erase a title it omitted")
        XCTAssertEqual(call.kind, "execute")
        XCTAssertEqual(call.output, "hello-from-acp\n")
    }

    /// An update for a call whose opening frame we never saw still has to pair.
    func testUpdateWithoutAnOpeningFrameStillPairs() {
        let stream = ACPSeamStream()
        let batch = stream.ingest(.toolCallUpdate(ACPToolCall(id: "call_x", status: .completed)))
        XCTAssertEqual(batch.kinds, [.toolUse, .toolResult])
        XCTAssertEqual(batch.openedToolUseIds, ["call_x"])
        XCTAssertEqual(batch.resolvedToolUseIds, ["call_x"])
    }

    // MARK: - Decoding real frames

    /// Verbatim `params` objects from the recorded `opencode acp` session.
    func testDecodesRecordedFrames() throws {
        let thought = try decodeUpdate("""
        {"sessionId":"ses_f72dbc6ceffejF3E29P22hnyOJ","update":{"sessionUpdate":"agent_thought_chunk",\
        "messageId":"msg_08d24394d001b5qols18wpvlzy","content":{"type":"text","text":" user asks a"}}}
        """)
        XCTAssertEqual(thought, .agentThought(messageId: "msg_08d24394d001b5qols18wpvlzy", text: " user asks a"))

        let opened = try decodeUpdate("""
        {"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"call_8c7b446e7e0f4b92bee8ef95",\
        "title":"bash","kind":"execute","status":"pending","locations":[{"path":"/tmp/scratch"}],\
        "rawInput":{"cwd":"/tmp/scratch"}}}
        """)
        XCTAssertEqual(opened, .toolCall(ACPToolCall(
            id: "call_8c7b446e7e0f4b92bee8ef95", title: "bash", kind: "execute",
            status: .pending, locations: ["/tmp/scratch"])))

        let completed = try decodeUpdate("""
        {"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1",\
        "status":"completed","title":"echo hello-from-acp",\
        "content":[{"type":"content","content":{"type":"text","text":"hello-from-acp\\n"}}],\
        "rawOutput":{"output":"hello-from-acp\\n","metadata":{"exit":0,"truncated":false}}}}
        """)
        XCTAssertEqual(completed, .toolCallUpdate(ACPToolCall(
            id: "call_1", title: "echo hello-from-acp", status: .completed, output: "hello-from-acp\n")))

        let usage = try decodeUpdate("""
        {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":99438,"size":200000,\
        "cost":{"amount":0,"currency":"USD"}}}
        """)
        XCTAssertEqual(usage, .usage(ACPUsage(used: 99438, size: 200000, costAmount: 0, costCurrency: "USD")))
    }

    /// An update kind we do not model is carried, not dropped and not fatal: agents
    /// add these between releases.
    func testUnknownUpdateKindIsCarried() throws {
        let update = try decodeUpdate("""
        {"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}
        """)
        XCTAssertEqual(update, .unhandled("available_commands_update"))
    }

    // MARK: - Against a real child process

    /// Handshake, a full turn, an answered permission request and a shutdown, over
    /// real stdio framing. The stand-in replays the frame sequence the real agent
    /// produced, including the chunking and the repeated `in_progress`.
    func testDrivesATurnAgainstARealChildProcess() async throws {
        let agent = try StandInACPAgent.make()
        defer { agent.cleanUp() }

        let seamEvents = EventLog()
        let permissions = EventLog()
        let client = ACPAgentClient(
            launch: .init(executable: "/bin/sh", arguments: [agent.path]),
            cwd: agent.directory,
            onPermission: { request in
                permissions.append(request.title ?? "")
                return request.options.first { $0.kind == "allow_once" }?.id
            },
            onSeamEvents: { batch in seamEvents.append(batch.kinds.map(\.rawValue).joined(separator: ",")) })
        defer { client.shutdown() }

        let name = try await client.connect(timeout: 20)
        XCTAssertEqual(name, "stand-in-acp")

        let sessionId = try await client.newSession(timeout: 20)
        XCTAssertEqual(sessionId, "ses_standin")

        let turn = try await client.prompt("count the sheep", timeout: 60)
        XCTAssertEqual(turn.stopReason, "end_turn")
        XCTAssertEqual(turn.inputTokens, 110)
        XCTAssertEqual(turn.cachedReadTokens, 99328)

        XCTAssertEqual(permissions.values, ["echo hello-from-acp"],
                       "the agent asked once and the turn only continued because we answered")

        // Seam events are produced on the ingest queue, so let it drain.
        try await waitUntil { seamEvents.values.count >= 4 }
        XCTAssertEqual(seamEvents.values, ["thinking", "tool_use", "tool_result", "assistant"],
                       "one event per run, in the order the turn produced them")

        XCTAssertEqual(client.seam.text(of: .thinking), "The user asks a riddle about sheep.")
        XCTAssertEqual(client.seam.text(of: .assistant), "9 sheep are left.")
        XCTAssertEqual(client.seam.usage, ACPUsage(used: 99438, size: 200000, costAmount: 0, costCurrency: "USD"))
    }

    /// A refused permission is reported to the agent as an outcome, not by hanging:
    /// the turn still completes, with the agent's own stop reason.
    func testRefusedPermissionStillEndsTheTurn() async throws {
        let agent = try StandInACPAgent.make()
        defer { agent.cleanUp() }

        let client = ACPAgentClient(
            launch: .init(executable: "/bin/sh", arguments: [agent.path]),
            cwd: agent.directory,
            onPermission: { _ in nil })
        defer { client.shutdown() }

        try await client.connect(timeout: 20)
        _ = try await client.newSession(timeout: 20)
        let turn = try await client.prompt("count the sheep", timeout: 60)
        XCTAssertEqual(turn.stopReason, "end_turn")
    }

    /// The client refuses to talk to an agent that answers a protocol revision it
    /// does not implement, instead of proceeding and failing later on a shape change.
    func testHandshakeRejectsAnUnknownProtocolVersion() async throws {
        let agent = try StandInACPAgent.make(protocolVersion: 99)
        defer { agent.cleanUp() }

        let client = ACPAgentClient(
            launch: .init(executable: "/bin/sh", arguments: [agent.path]),
            cwd: agent.directory,
            onPermission: { _ in nil })
        defer { client.shutdown() }

        do {
            try await client.connect(timeout: 20)
            XCTFail("expected the handshake to be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("v99"), "got: \(error)")
        }
    }

    // MARK: - Helpers

    private func decodeUpdate(_ json: String) throws -> ACPUpdate {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let params = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(ACPUpdate.decode(params))
    }

    /// Poll until `condition` holds or a short deadline passes. Bounded, so a failure
    /// is a failing assertion rather than a hung suite.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            await Nap.ms(25)
        }
    }
}

/// Ordered, thread-safe collection point for callbacks that fire off the test thread.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// A real process that speaks ACP on its stdio, replaying the frame sequence recorded
/// from `opencode acp`. Plain `/bin/sh` on purpose: the point is that the bytes on the
/// pipe are the bytes a real agent writes, and adding a runtime to produce them would
/// only add a way for the test to be skipped.
private struct StandInACPAgent {
    let directory: String
    let path: String

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    static func make(protocolVersion: Int = 1) throws -> StandInACPAgent {
        let directory = NSTemporaryDirectory() + "acp-standin-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/agent.sh"
        try script(protocolVersion: protocolVersion).write(toFile: path, atomically: true, encoding: .utf8)
        return StandInACPAgent(directory: directory, path: path)
    }

    private static func script(protocolVersion: Int) -> String {
        """
        #!/bin/sh
        # Stand-in ACP agent: newline-framed JSON-RPC 2.0 on stdio.
        say() { printf '%s\\n' "$1"; }
        rid() { printf '%s' "$1" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p'; }
        chunk() {
          say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_standin","update":{"sessionUpdate":"'"$1"'","messageId":"'"$2"'","content":{"type":"text","text":"'"$3"'"}}}}'
        }

        while IFS= read -r line; do
          id=$(rid "$line")
          case "$line" in
            *'"method":"initialize"'*)
              say '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":\(protocolVersion),"agentInfo":{"name":"stand-in-acp"}}}'
              ;;
            *'"method":"session/new"'*)
              say '{"jsonrpc":"2.0","id":'"$id"',"result":{"sessionId":"ses_standin"}}'
              ;;
            *'"method":"session/prompt"'*)
              # Reasoning, chunked the way the real agent chunks it.
              chunk agent_thought_chunk msg_1 'The'
              chunk agent_thought_chunk msg_1 ' user asks a'
              chunk agent_thought_chunk msg_1 ' r'
              chunk agent_thought_chunk msg_1 'iddle about sheep.'
              say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_standin","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"bash","kind":"execute","status":"pending","locations":[{"path":"/tmp"}]}}}'
              # The turn blocks here until the client answers, exactly as the real one does.
              say '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"ses_standin","toolCall":{"toolCallId":"call_1","title":"echo hello-from-acp","kind":"execute"},"options":[{"optionId":"once","kind":"allow_once","name":"Allow once"},{"optionId":"reject","kind":"reject_once","name":"Reject"}]}}'
              IFS= read -r _answer
              i=0
              while [ $i -lt 3 ]; do
                say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_standin","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"in_progress","kind":"execute","title":"echo hello-from-acp"}}}'
                i=$((i + 1))
              done
              say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_standin","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","title":"echo hello-from-acp","content":[{"type":"content","content":{"type":"text","text":"hello-from-acp\\n"}}]}}}'
              chunk agent_message_chunk msg_2 '9 sheep'
              chunk agent_message_chunk msg_2 ' are left.'
              say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_standin","update":{"sessionUpdate":"usage_update","used":99438,"size":200000,"cost":{"amount":0,"currency":"USD"}}}}'
              say '{"jsonrpc":"2.0","id":'"$id"',"result":{"stopReason":"end_turn","usage":{"inputTokens":110,"outputTokens":13,"totalTokens":99451,"cachedReadTokens":99328}}}'
              ;;
          esac
        done
        """
    }
}
