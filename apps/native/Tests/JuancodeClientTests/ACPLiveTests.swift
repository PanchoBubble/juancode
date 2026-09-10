import XCTest
import JuancodeCore
@testable import JuancodeClient

/// The ACP client against a real agent binary, off by default.
///
/// `ACPClientTests` proves the framing and the seam mapping against a stand-in that
/// replays recorded frames; this proves the recording still matches reality. Gated
/// like the other live suites here — an agent binary is not something a checkout is
/// entitled to assume, and this one talks to a provider.
///
///     JUANCODE_ACP_LIVE_BIN=$(command -v opencode) \
///       swift test --package-path apps/native --filter ACPLiveTests
///
/// The handshake case sends no prompt, so it reaches no model and costs nothing.
final class ACPLiveTests: XCTestCase {

    private func liveClient(onPermission: @escaping @Sendable (ACPAgentClient.PermissionRequest) -> String?
                            = { _ in nil }) throws -> ACPAgentClient {
        guard let binary = ProcessInfo.processInfo.environment["JUANCODE_ACP_LIVE_BIN"],
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("set JUANCODE_ACP_LIVE_BIN to an ACP agent binary (e.g. $(command -v opencode)) to run these")
        }
        return ACPAgentClient(launch: ACPLaunch.opencode(binary: binary),
                              cwd: NSTemporaryDirectory(),
                              onPermission: onPermission)
    }

    /// Handshake and open a conversation against the real binary. Free: no prompt.
    func testHandshakeAndSessionAgainstTheRealAgent() async throws {
        let client = try liveClient()
        defer { client.shutdown() }

        let name = try await client.connect(timeout: 60)
        XCTAssertNotNil(name, "the agent should identify itself in agentInfo")

        let sessionId = try await client.newSession(timeout: 60)
        XCTAssertFalse(sessionId.isEmpty)
    }

    /// One real turn. Costs a model call, so it needs a second opt-in on top of the
    /// binary: `JUANCODE_ACP_LIVE_PROMPT=1`.
    func testRealTurnSuppliesReasoningText() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUANCODE_ACP_LIVE_PROMPT"] == "1",
                          "set JUANCODE_ACP_LIVE_PROMPT=1 to spend a real model call")
        let client = try liveClient(onPermission: { request in
            request.options.first { $0.kind == "allow_once" }?.id
        })
        defer { client.shutdown() }

        try await client.connect(timeout: 60)
        _ = try await client.newSession(timeout: 60)
        let turn = try await client.prompt(
            "Think step by step, then answer: a farmer has 17 sheep, all but 9 run away. How many are left?",
            timeout: 300)

        XCTAssertFalse(turn.stopReason.isEmpty)
        XCTAssertFalse(client.seam.text(of: .assistant).isEmpty, "the turn produced no answer text")
        XCTAssertFalse(client.seam.text(of: .thinking).isEmpty,
                       "this agent was measured to emit agent_thought_chunk — if this is empty it stopped")
    }
}
