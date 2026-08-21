import Foundation

/// One WebSocket connection to a remote core, speaking the frames in
/// `apps/wire-conformance/spec/v1/protocol.json`.
///
/// Deliberately thin: it owns the socket, the JSON, the handshake wait and the
/// reconnect, and hands every decoded frame to one callback. Everything that
/// knows what a frame *means* lives in `RustCoreClient`, so the transport can be
/// swapped (a unix socket is what `juancoded` really wants us on) without
/// touching the semantics.
final class WireConnection: @unchecked Sendable {
    /// A frame as it arrived: the discriminator plus the flat object it rode in.
    /// Frames are flat by spec ("every field sits alongside `type`"), so a
    /// dictionary is the whole shape and no envelope type is needed.
    typealias Frame = (type: String, body: [String: Any])

    enum ConnectError: LocalizedError {
        case badURL(String)
        case timedOut(seconds: Double, url: String)
        case closed(url: String, reason: String)
        case unsupportedProtocol(theirs: Int, ours: Int)

        var errorDescription: String? {
            switch self {
            case .badURL(let url):
                return "Not a usable core URL: \(url)"
            case let .timedOut(seconds, url):
                return "No serverInfo handshake from \(url) within \(Int(seconds * 1000))ms"
            case let .closed(url, reason):
                return "Could not reach \(url): \(reason)"
            case let .unsupportedProtocol(theirs, ours):
                return "The core speaks wire protocol v\(theirs); this app implements v\(ours)"
            }
        }
    }

    /// The handshake, once it has landed.
    struct Handshake: Sendable {
        let protocolVersion: Int
        let capabilities: [String]
        /// This connection's grid-ownership token. Absent on cores that predate
        /// `serverInfo.clientId`, which is the same set that has no `gridOwner`.
        let clientId: String?
    }

    private let url: URL
    private let session: URLSession
    private let lock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var handshake: Handshake?
    private var handshakeWaiters: [DispatchSemaphore] = []
    private var closedReason: String?
    private var stopped = false

    /// Every decoded frame, in arrival order, on the URLSession delegate queue.
    private let onFrame: @Sendable (Frame) -> Void
    /// Fires when the socket drops and when it comes back, so the UI can say so
    /// instead of quietly showing a frozen session.
    private let onConnectionChange: @Sendable (Bool, String?) -> Void

    init(url: URL,
         onFrame: @escaping @Sendable (Frame) -> Void,
         onConnectionChange: @escaping @Sendable (Bool, String?) -> Void) {
        self.url = url
        self.onFrame = onFrame
        self.onConnectionChange = onConnectionChange
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    /// Turn a base URL (`http://127.0.0.1:4290`) into the `/ws` endpoint.
    static func websocketURL(base: String) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw ConnectError.badURL(base) }
        switch comps.scheme {
        case "http", nil: comps.scheme = "ws"
        case "https": comps.scheme = "wss"
        case "ws", "wss": break
        default: throw ConnectError.badURL(base)
        }
        comps.path = "/ws"
        guard let url = comps.url else { throw ConnectError.badURL(base) }
        return url
    }

    /// Open the socket and block until `serverInfo` lands, so a caller knows the
    /// capability list before it hands the client to any UI. The spec makes this
    /// safe to wait on: `serverInfo` is frame 0 on every connection.
    func connectAndWaitForHandshake(timeout: TimeInterval, expectedVersion: Int) throws -> Handshake {
        openSocket()
        let waiter = DispatchSemaphore(value: 0)
        let already: Handshake? = lock.withLock {
            if let handshake { return handshake }
            handshakeWaiters.append(waiter)
            return nil
        }
        if let already { return already }
        if waiter.wait(timeout: .now() + timeout) == .timedOut {
            let reason = lock.withLock { closedReason }
            stop()
            if let reason { throw ConnectError.closed(url: url.absoluteString, reason: reason) }
            throw ConnectError.timedOut(seconds: timeout, url: url.absoluteString)
        }
        guard let landed = lock.withLock({ handshake }) else {
            let reason = lock.withLock { closedReason } ?? "no handshake"
            stop()
            throw ConnectError.closed(url: url.absoluteString, reason: reason)
        }
        guard landed.protocolVersion == expectedVersion else {
            stop()
            throw ConnectError.unsupportedProtocol(theirs: landed.protocolVersion,
                                                   ours: expectedVersion)
        }
        return landed
    }

    /// Send one client frame. Fire-and-forget: the protocol acks what needs
    /// acking (`inputAck`, `resizeAck`) at the frame level, so a send failure is a
    /// connection problem, which `onConnectionChange` already reports.
    func send(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("juancode: could not encode a \(body["type"] ?? "?") frame")
            return
        }
        let task = lock.withLock { self.task }
        guard let task else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.dropped("send failed: \(error.localizedDescription)") }
        }
    }

    /// Close for good. Idempotent, and stops the reconnect loop.
    func stop() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            stopped = true
            let t = self.task
            self.task = nil
            return t
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Socket plumbing

    private func openSocket() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard !stopped, self.task == nil else { return nil }
            let t = session.webSocketTask(with: url)
            self.task = t
            closedReason = nil
            return t
        }
        guard let task else { return }
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text: text)
                case .data(let data): self.handle(text: String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive(on: task)
            case .failure(let error):
                self.dropped(error.localizedDescription)
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = body["type"] as? String else {
            // A core that sends us junk is a core bug, not a reason to tear the
            // connection down: the same tolerance the spec asks of a core.
            NSLog("juancode: undecodable frame from the core (\(text.prefix(120)))")
            return
        }
        if type == "serverInfo" {
            let landed = Handshake(protocolVersion: body["protocolVersion"] as? Int ?? 0,
                                   capabilities: body["capabilities"] as? [String] ?? [],
                                   clientId: body["clientId"] as? String)
            let waiters: [DispatchSemaphore] = lock.withLock {
                handshake = landed
                let w = handshakeWaiters
                handshakeWaiters = []
                return w
            }
            for w in waiters { w.signal() }
            onConnectionChange(true, nil)
            return
        }
        onFrame((type: type, body: body))
    }

    private func dropped(_ reason: String) {
        let shouldReport: Bool = lock.withLock {
            guard !stopped, closedReason == nil else { return false }
            closedReason = reason
            task = nil
            return true
        }
        guard shouldReport else { return }
        onConnectionChange(false, reason)
        // Retry rather than leaving the app pointed at a dead core: a daemon
        // restart is the common case, and every session handle we hold is
        // re-attachable by id once the socket is back.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.openSocket()
        }
    }
}
