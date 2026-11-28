import Foundation
import JuancodeWire

/// The one connection to the Mac: `/ws` on the relay plus its REST reads, both
/// carrying the pairing token. Knows frames, not views: it keeps the session rows
/// and their activity, and hands a session's terminal bytes to whoever attached.
@MainActor @Observable
final class RemoteCore {
    let pairing: Pairing
    private(set) var sessions: [SessionMeta] = []
    private(set) var activity: [String: SessionActivity] = [:]
    private(set) var connected = false
    private(set) var lastError: String?

    /// Terminal bytes for the attached session: `attached` scrollback, then `output`.
    @ObservationIgnored var onTerminalBytes: ((String, [UInt8]) -> Void)?
    @ObservationIgnored private var wire: WireConnection?
    /// Re-sent after a reconnect, so the open terminal picks up where it left off.
    @ObservationIgnored private var attachedTo: (id: String, cols: Int, rows: Int)?

    init(pairing: Pairing) { self.pairing = pairing }

    func start() {
        guard wire == nil else { return }
        do {
            var comps = URLComponents(url: try WireConnection.websocketURL(base: pairing.server.absoluteString),
                                      resolvingAgainstBaseURL: false)!
            // The relay accepts `?token=` as well as a Bearer header; URLSession's
            // WebSocket task takes a bare URL in WireConnection, so the query it is.
            comps.queryItems = [URLQueryItem(name: "token", value: pairing.token)]
            let conn = WireConnection(
                url: comps.url!,
                onFrame: { [weak self] frame in
                    guard let data = try? JSONSerialization.data(withJSONObject: frame.body) else { return }
                    let type = frame.type
                    // Not `Task {}`: terminal bytes must land in arrival order.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(type: type, data: data) } }
                },
                onConnectionChange: { [weak self] up, reason in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionChanged(up: up, reason: reason) } }
                })
            wire = conn
            Task.detached {
                do {
                    _ = try conn.connectAndWaitForHandshake(timeout: 10, expectedVersion: WireProtocol.version)
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        wire?.stop()
        wire = nil
        connected = false
    }

    func refreshSessions() async {
        var req = URLRequest(url: pairing.server.appending(path: "api/sessions"))
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                lastError = "The Mac rejected the pairing token. Scan the QR again."
                return
            }
            sessions = try JSONDecoder().decode([SessionMeta].self, from: data)
        } catch {
            lastError = "Could not list sessions: \(error.localizedDescription)"
        }
    }

    // MARK: Client frames

    func attach(_ id: String, cols: Int, rows: Int) {
        attachedTo = (id, cols, rows)
        send(["type": "attach", "sessionId": id, "cols": cols, "rows": rows])
    }
    func resize(_ id: String, cols: Int, rows: Int) {
        send(["type": "resize", "sessionId": id, "cols": cols, "rows": rows])
    }
    func input(_ id: String, _ text: String) {
        send(["type": "input", "sessionId": id, "data": text])
    }
    /// Named keys (Escape, Up, C-c, …), resolved by the core — see `named_key.rs`.
    func keys(_ id: String, _ names: [String]) {
        send(["type": "key", "sessionId": id, "keys": names])
    }

    private func send(_ body: [String: Any]) { wire?.send(body) }

    // MARK: Server frames

    private func connectionChanged(up: Bool, reason: String?) {
        connected = up
        lastError = up ? nil : reason
        guard up else { return }
        Task { await refreshSessions() }
        if let a = attachedTo { attach(a.id, cols: a.cols, rows: a.rows) }
    }

    private func handle(type: String, data: Data) {
        struct Frame: Decodable {
            var sessionId: String?
            var session: SessionMeta?
            var state: SessionActivity?
            var data: String?
            var scrollback: String?
            var message: String?
        }
        guard let f = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        switch type {
        case "activity":
            if let id = f.sessionId, let state = f.state { activity[id] = state }
        case "created", "sessionMeta", "attached":
            if let meta = f.session { upsert(meta) }
            if type == "attached", let id = f.sessionId, let bytes = f.scrollback {
                onTerminalBytes?(id, Array(bytes.utf8))
            }
        case "output":
            if let id = f.sessionId, let bytes = f.data { onTerminalBytes?(id, Array(bytes.utf8)) }
        case "exit":
            if let id = f.sessionId, let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].status = .exited
            }
        case "error":
            lastError = f.message
        default:
            break
        }
    }

    private func upsert(_ meta: SessionMeta) {
        if let i = sessions.firstIndex(where: { $0.id == meta.id }) { sessions[i] = meta } else { sessions.append(meta) }
    }
}
