import Foundation
import JuancodeCore

/// Drives one agent over the Agent Client Protocol: a second transport alongside the
/// pty, not a replacement for it.
///
/// The pty path stays the default and stays faithful — it spawns the genuine CLI in
/// a terminal with the user's environment inherited untouched, which is what makes
/// user-scope MCP servers and account connectors load exactly as they do in a shell.
/// This adds a way to *also* get turns, reasoning, tool calls and per-turn usage as
/// structured events, for the agents that can supply them.
///
/// Which agents those are, measured on this machine 2026-09-10 (juancode-6582):
///
/// - `opencode acp` (opencode 1.18.25) speaks ACP natively and emits real reasoning
///   text: 21 `agent_thought_chunk` notifications in one probed turn.
/// - claude 2.1.268 does not speak ACP at all. The third-party
///   `@zed-industries/claude-code-acp` wrapper does, and completes a turn — but emits
///   ZERO thought chunks, because claude's thinking blocks are empty (juancode-bqw0).
///   ACP is not a way to recover claude's reasoning.
/// - codex-cli 0.153.0 does not speak ACP; it has its own `app-server` protocol.
///
/// This client is not yet wired into session creation. That step needs a transport
/// flag on `CoreClient.create`, which ripples into both cores, `WireProtocol.swift`
/// and the sidecar's mirror — a wide change whose payoff for the default provider
/// the spike measured at zero. `ACPLaunch.opencode` is here so the wiring, when it
/// happens, has one place to name a partner.
public final class ACPAgentClient: @unchecked Sendable {

    /// What the agent asked permission for, and what it will accept as an answer.
    public struct PermissionRequest: Sendable {
        public var toolCallId: String?
        public var title: String?
        /// `(optionId, kind)` pairs as the agent offered them — kinds seen in the
        /// probe: `allow_once`, `allow_always`, `reject_once`, `reject_always`.
        public var options: [(id: String, kind: String)]
    }

    /// How to reach an agent that speaks ACP.
    public struct Launch: Sendable {
        public var executable: String
        public var arguments: [String]
        public var unsetEnvironment: [String]

        public init(executable: String, arguments: [String], unsetEnvironment: [String] = []) {
            self.executable = executable
            self.arguments = arguments
            self.unsetEnvironment = unsetEnvironment
        }
    }

    /// The answer to `session/prompt`: why the turn ended, and what it cost.
    public struct TurnResult: Sendable, Equatable {
        public var stopReason: String
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var totalTokens: Int?
        public var cachedReadTokens: Int?
    }

    public enum ClientError: LocalizedError {
        case notRunning
        case noSession
        case badHandshake(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:
                return "The ACP agent is not running — call connect() first"
            case .noSession:
                return "No ACP session — call connect() then newSession() first"
            case let .badHandshake(detail):
                return "The ACP agent's handshake was not usable: \(detail)"
            }
        }
    }

    /// The protocol revision this client implements. ACP negotiates on `initialize`;
    /// every agent probed answered 1.
    public static let protocolVersion = 1

    /// Everything the turn has produced, kinds and text in one pass.
    public let seam = ACPSeamStream()

    private let launch: Launch
    private let cwd: String
    private let onSeamEvents: (@Sendable (StructuredEventBatch) -> Void)?
    private let onPermission: @Sendable (PermissionRequest) -> String?
    private var transport: ACPStdioTransport?
    private let lock = NSLock()
    private var sessionId: String?
    /// Ingestion is serialised here: notifications arrive on the pipe's reader
    /// thread, and `ACPSeamStream` is not thread-safe.
    private let ingestQueue = DispatchQueue(label: "juancode.acp.ingest")

    /// `onPermission` returns the `optionId` to choose, or nil to refuse. It has no
    /// default on purpose: an agent asking to run a command is a decision, and a
    /// client that silently answers "allow" for a caller that never thought about it
    /// is the wrong shape for a harness the user is meant to be steering.
    public init(launch: Launch,
                cwd: String,
                onPermission: @escaping @Sendable (PermissionRequest) -> String?,
                onSeamEvents: (@Sendable (StructuredEventBatch) -> Void)? = nil) {
        self.launch = launch
        self.cwd = cwd
        self.onPermission = onPermission
        self.onSeamEvents = onSeamEvents
    }

    /// Spawn the agent and complete the ACP handshake. Returns the agent's
    /// self-reported name, when it gives one.
    @discardableResult
    public func connect(timeout: TimeInterval = 30) async throws -> String? {
        let transport = ACPStdioTransport(
            launch: .init(executable: launch.executable, arguments: launch.arguments,
                          cwd: cwd, unsetEnvironment: launch.unsetEnvironment),
            onNotification: { [weak self] method, params in
                self?.handle(notification: method, params)
            },
            onRequest: { [weak self] method, params in
                self?.handle(request: method, params)
            })
        lock.withLock { self.transport = transport }
        try transport.start()

        // We answer no filesystem or terminal requests: the agent does its own IO,
        // and claiming capabilities we have not implemented would strand a turn on a
        // request we cannot serve.
        let result = try await transport.request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ], timeout: timeout)

        guard let version = result["protocolVersion"] as? Int else {
            throw ClientError.badHandshake("no protocolVersion in the initialize result")
        }
        guard version == Self.protocolVersion else {
            throw ClientError.badHandshake("agent speaks v\(version), this client implements v\(Self.protocolVersion)")
        }
        return (result["agentInfo"] as? [String: Any])?["name"] as? String
    }

    /// Open a conversation rooted at `cwd`. `mcpServers` stays empty: the agent loads
    /// the user's own MCP configuration itself, and passing a list here would be the
    /// shadow configuration the prime directive forbids.
    @discardableResult
    public func newSession(timeout: TimeInterval = 60) async throws -> String {
        guard let transport = currentTransport() else { throw ClientError.notRunning }
        let result = try await transport.request(
            "session/new", ["cwd": cwd, "mcpServers": []], timeout: timeout)
        guard let id = result["sessionId"] as? String else {
            throw ClientError.badHandshake("no sessionId in the session/new result")
        }
        lock.withLock { sessionId = id }
        return id
    }

    /// Run one turn. Returns when the agent stops; everything it produced on the way
    /// has already been folded into `seam` and reported through `onSeamEvents`.
    public func prompt(_ text: String, timeout: TimeInterval = 900) async throws -> TurnResult {
        guard let transport = currentTransport() else { throw ClientError.notRunning }
        let id = lock.withLock { sessionId }
        guard let id else { throw ClientError.noSession }

        let result = try await transport.request("session/prompt", [
            "sessionId": id,
            "prompt": [["type": "text", "text": text]],
        ], timeout: timeout)

        let usage = result["usage"] as? [String: Any]
        return TurnResult(
            stopReason: result["stopReason"] as? String ?? "unknown",
            inputTokens: usage?["inputTokens"] as? Int,
            outputTokens: usage?["outputTokens"] as? Int,
            totalTokens: usage?["totalTokens"] as? Int,
            cachedReadTokens: usage?["cachedReadTokens"] as? Int)
    }

    /// Interrupt the turn in flight. Best-effort: `session/cancel` is a notification,
    /// so there is nothing to await and nothing to fail.
    public func cancel() {
        let (id, transport) = lock.withLock { (sessionId, self.transport) }
        guard let id, let transport else { return }
        try? transport.notify("session/cancel", ["sessionId": id])
    }

    /// Stop the agent process. Safe to call twice.
    public func shutdown() {
        let transport = lock.withLock { () -> ACPStdioTransport? in
            defer { self.transport = nil }
            return self.transport
        }
        transport?.stop()
    }

    private func currentTransport() -> ACPStdioTransport? {
        lock.withLock { transport }
    }

    private func handle(notification method: String, _ params: [String: Any]) {
        guard method == "session/update", let update = ACPUpdate.decode(params) else { return }
        ingestQueue.async { [weak self] in
            guard let self else { return }
            let batch = self.seam.ingest(update)
            guard !batch.kinds.isEmpty else { return }
            self.onSeamEvents?(batch)
        }
    }

    private func handle(request method: String, _ params: [String: Any]) -> [String: Any]? {
        guard method == "session/request_permission" else { return nil }
        let toolCall = params["toolCall"] as? [String: Any]
        let options = (params["options"] as? [Any] ?? []).compactMap { option -> (id: String, kind: String)? in
            guard let option = option as? [String: Any], let id = option["optionId"] as? String else { return nil }
            return (id, option["kind"] as? String ?? "")
        }
        let chosen = onPermission(PermissionRequest(
            toolCallId: toolCall?["toolCallId"] as? String,
            title: toolCall?["title"] as? String,
            options: options))
        guard let chosen else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": chosen]]
    }
}

/// The agents on this machine that are known to speak ACP, and how to launch them.
///
/// A short list on purpose: it names only partners a probe actually completed a turn
/// against, so nothing here is aspirational. Extend it by measuring, not by reading
/// a release note.
public enum ACPLaunch {
    /// `opencode acp`. The one agent installed here that speaks ACP natively, and the
    /// only source of real reasoning text among the three.
    public static func opencode(binary: String = "opencode") -> ACPAgentClient.Launch {
        .init(executable: binary, arguments: ["acp"])
    }

    /// The third-party Zed wrapper around Claude Code. Completes turns and reports
    /// tool calls, but supplies no reasoning text — see the note on `ACPAgentClient`.
    /// It refuses to start a session when it inherits a Claude Code session's
    /// environment, so those names are dropped.
    public static func claudeCodeACP(binary: String) -> ACPAgentClient.Launch {
        .init(executable: binary, arguments: [],
              unsetEnvironment: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                                 "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_EXECPATH",
                                 "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN"])
    }
}
