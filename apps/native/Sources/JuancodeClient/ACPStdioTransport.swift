import Foundation
import JuancodeCore

/// JSON-RPC 2.0 over a child process's stdin/stdout, framed by newlines.
///
/// Deliberately thin, the same split `WireConnection` makes: it owns the process,
/// the framing, the id correlation and the timeouts, and knows nothing about what a
/// method means. `ACPAgentClient` holds all the ACP semantics.
///
/// The framing is newline-delimited, NOT the `Content-Length` header framing LSP
/// uses. Both are "JSON-RPC over stdio" and they are not interchangeable; a client
/// that sends LSP framing to `opencode acp` is simply never answered. Verified
/// against the real binary.
///
/// Traffic runs both ways: the agent answers our requests, sends `session/update`
/// notifications, and makes requests of its own (`session/request_permission` is the
/// one that matters — the turn stalls until it is answered).
final class ACPStdioTransport: @unchecked Sendable {

    enum TransportError: LocalizedError {
        case notRunning
        case timedOut(method: String, seconds: Double)
        case remote(method: String, code: Int, message: String)
        case exited(code: Int32)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "The ACP agent process is not running"
            case let .timedOut(method, seconds):
                return "No answer to ACP \(method) within \(Int(seconds))s"
            case let .remote(method, code, message):
                return "ACP \(method) failed (\(code)): \(message)"
            case let .exited(code):
                return "The ACP agent exited with status \(code)"
            }
        }
    }

    /// How the child is launched.
    ///
    /// The environment is inherited untouched — the prime directive for the pty path
    /// applies here for the same reason: user-scope MCP servers, account connectors
    /// and provider credentials all come from it, and an agent started with a shadow
    /// environment is a different agent. `unsetEnvironment` is the one lever, and it
    /// exists for one measured case: `@zed-industries/claude-code-acp` refuses to
    /// start a session when `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT` are inherited
    /// ("Claude Code cannot be launched inside another Claude Code session"), so a
    /// juancode session that itself spawns one has to drop those names. It removes
    /// names; it never sets values.
    struct Launch: Sendable {
        var executable: String
        var arguments: [String]
        var cwd: String
        var unsetEnvironment: [String] = []

        init(executable: String, arguments: [String], cwd: String, unsetEnvironment: [String] = []) {
            self.executable = executable
            self.arguments = arguments
            self.cwd = cwd
            self.unsetEnvironment = unsetEnvironment
        }
    }

    private let launch: Launch
    private let onNotification: @Sendable (String, [String: Any]) -> Void
    /// Answers a request the agent makes of us. Returning nil sends a JSON-RPC error
    /// back, which is how a refused permission is reported.
    private let onRequest: @Sendable (String, [String: Any]) -> [String: Any]?
    private let onStderr: (@Sendable (String) -> Void)?
    private let onExit: (@Sendable (Int32) -> Void)?

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var running = false
    /// Bytes of a line that has not arrived whole yet. Split at the byte level, so a
    /// multi-byte UTF-8 character straddling a read boundary is never mis-decoded.
    private var inbox = Data()

    init(launch: Launch,
         onNotification: @escaping @Sendable (String, [String: Any]) -> Void,
         onRequest: @escaping @Sendable (String, [String: Any]) -> [String: Any]?,
         onStderr: (@Sendable (String) -> Void)? = nil,
         onExit: (@Sendable (Int32) -> Void)? = nil) {
        self.launch = launch
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onStderr = onStderr
        self.onExit = onExit
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        var environment = ProcessInfo.processInfo.environment
        for name in launch.unsetEnvironment { environment.removeValue(forKey: name) }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        if let onStderr {
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                onStderr(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(TransportError.exited(code: process.terminationStatus))
            self?.onExit?(process.terminationStatus)
        }

        try process.run()
        lock.lock(); running = true; lock.unlock()
    }

    /// Send a request and await its answer. `timeout` is a ceiling, not a deadline
    /// the agent knows about: a turn that outlives it leaves the child running, so
    /// callers that time out should also `stop()`.
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = try lock.withLock {
            guard running else { throw TransportError.notRunning }
            nextId += 1
            return nextId
        }

        let timer = Task { [weak self] in
            await Nap.duration(.milliseconds(Int(timeout * 1000)))
            guard !Task.isCancelled else { return }
            self?.fail(id, TransportError.timedOut(method: method, seconds: timeout))
        }
        defer { timer.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock { () -> Bool in
                guard running else { return false }
                pending[id] = continuation
                return true
            }
            guard accepted else { return continuation.resume(throwing: TransportError.notRunning) }
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                fail(id, error)
            }
        }
    }

    /// Send a notification — no id, no answer expected.
    func notify(_ method: String, _ params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
        finish(TransportError.notRunning)
    }

    // MARK: - Framing

    /// `withoutEscapingSlashes` is not cosmetic here: the default writer emits
    /// `"session\/new"`, which is valid JSON every parser accepts but is not what any
    /// other ACP client puts on the wire — and an agent that pattern-matches the
    /// method name instead of parsing simply never answers.
    private func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Every slice taken here is copied back into a fresh `Data` rather than kept as
    /// a slice. A `Data` slice keeps the *base* buffer's indices, so the remainder
    /// after the first newline starts at a non-zero `startIndex` — and
    /// `JSONSerialization` reads such a slice from the base buffer's start, not from
    /// its own. The first frame parses, every frame after it silently does not, and a
    /// dropped frame here looks exactly like an agent that never answered.
    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        inbox.append(data)
        while let newline = inbox.firstIndex(of: 0x0A) {
            lines.append(Data(inbox[inbox.startIndex..<newline]))
            inbox = Data(inbox[inbox.index(after: newline)...])
        }
        lock.unlock()
        for line in lines where !line.isEmpty { dispatch(line) }
    }

    private func dispatch(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let id = message["id"] as? Int

        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            guard let id else { return onNotification(method, params) }
            // A request of us. Answering is not optional: an unanswered
            // `session/request_permission` stalls the turn forever.
            if let result = onRequest(method, params) {
                try? write(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                try? write(["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32001, "message": "Refused by juancode"]])
            }
            return
        }

        guard let id else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: TransportError.remote(
                method: "#\(id)",
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "unknown"))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// Fail every request still in flight, once. Called when the child dies and when
    /// we stop it, so no caller is left awaiting an answer that can never come.
    private func finish(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        running = false
        lock.unlock()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
