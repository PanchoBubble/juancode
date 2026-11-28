import Foundation
import UIKit
import JuancodeWire

/// The one connection to the Mac: `/ws` on the relay plus its REST reads, both
/// carrying the pairing token. Knows frames, not views: it keeps the session rows
/// and their activity, and hands a session's terminal bytes to whoever attached.
@MainActor @Observable
final class RemoteCore {
    let pairing: Pairing
    private(set) var sessions: [SessionMeta] = []
    private(set) var activity: [String: SessionActivity] = [:]
    private(set) var trackedPrs: [TrackedPrInfo] = []
    private(set) var chains = ChainBook()
    private(set) var handoffs = ChainHandoffBook()
    private(set) var connected = false
    private(set) var lastError: String?

    /// Terminal bytes for the attached session: `attached` scrollback, then `output`.
    @ObservationIgnored var onTerminalBytes: ((String, [UInt8]) -> Void)?
    /// Sessions whose shared grid another client (the Mac) drives, at its cols/rows. The phone's
    /// resize is denied there, so its terminal must lay out at that grid or the bytes garble.
    @ObservationIgnored private(set) var foreignGrid: [String: (cols: Int, rows: Int)] = [:]
    /// Called when a session's `foreignGrid` entry changes; nil means the phone may drive it.
    @ObservationIgnored var onGrid: ((String, (cols: Int, rows: Int)?) -> Void)?
    /// Called with the id of the session a `create` from this phone produced.
    @ObservationIgnored var onCreated: ((String) -> Void)?
    @ObservationIgnored private var awaitingCreate = false
    @ObservationIgnored private var wire: WireConnection?
    /// Re-sent after a reconnect, so the open terminal picks up where it left off.
    @ObservationIgnored private var attachedTo: (id: String, cols: Int, rows: Int)?

    init(pairing: Pairing) {
        self.pairing = pairing
        let nc = NotificationCenter.default
        // Back in front: the phone is what the user is driving again. Away: let the Mac have it.
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let a = self?.attachedTo { self?.take(a.id) } }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let a = self?.attachedTo { self?.send(["type": "releaseGrid", "sessionId": a.id]) } }
        }
    }

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

    /// Opening a session is driving it: attach, then take the grid at the phone's size, so the pty
    /// reflows to it as it does to the Mac's pane (juancode-3aq8.26).
    func attach(_ id: String, cols: Int, rows: Int) {
        attachedTo = (id, cols, rows)
        send(["type": "attach", "sessionId": id, "cols": cols, "rows": rows])
        take(id)
    }
    /// Leaving the session: hand the grid back so the Mac reflows to its own pane.
    func leave(_ id: String) {
        guard attachedTo?.id == id else { return }
        attachedTo = nil
        send(["type": "releaseGrid", "sessionId": id])
    }
    /// Take the grid at the phone's own size. A core without `take` denies it silently and keeps
    /// broadcasting the Mac's grid, so after a beat fall back to following (zoom to fit) that.
    private func take(_ id: String) {
        guard let a = attachedTo, a.id == id else { return }
        send(["type": "resize", "sessionId": id, "cols": a.cols, "rows": a.rows, "take": true])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if attachedTo?.id == id, let g = foreignGrid[id] { onGrid?(id, g) }
        }
    }
    /// Input means the user is driving from the phone: take the grid back if the Mac has it.
    private func drive(_ id: String) {
        if foreignGrid[id] != nil { take(id) }
    }
    func resize(_ id: String, cols: Int, rows: Int) {
        if attachedTo?.id == id { attachedTo = (id, cols, rows) }
        send(["type": "resize", "sessionId": id, "cols": cols, "rows": rows])
    }
    func input(_ id: String, _ text: String) {
        drive(id)
        send(["type": "input", "sessionId": id, "data": text])
    }
    /// Named keys (Escape, Up, C-c, …), resolved by the core — see `named_key.rs`.
    func keys(_ id: String, _ names: [String]) {
        drive(id)
        send(["type": "key", "sessionId": id, "keys": names])
    }
    /// A typed message: bracketed paste, then Enter a beat later, as the sidecar's `deliverReply`
    /// does. Text and Enter back to back read as one paste and the TUI can swallow the Enter.
    func submit(_ id: String, _ text: String) {
        if !text.isEmpty { input(id, "\u{1b}[200~\(text)\u{1b}[201~") }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(text.isEmpty ? 0 : 150))
            keys(id, ["Enter"])
        }
    }

    /// New agent session. `dispatchId` carries a `phone-` prefix: the core echoes it on every
    /// `activity` frame, which is how the sidecar tells a phone-started session (juancode-3aq8.7).
    func create(provider: ProviderId, cwd: String, model: String?, worktree: Bool) {
        awaitingCreate = true
        var body: [String: Any] = ["type": "create", "provider": provider.rawValue, "cwd": cwd,
                                   "isolateWorktree": worktree, "dispatchId": "phone-\(UUID().uuidString)"]
        if let model, !model.isEmpty { body["model"] = model }
        send(body)
    }

    private func send(_ body: [String: Any]) { wire?.send(body) }

    // MARK: Server frames

    private func connectionChanged(up: Bool, reason: String?) {
        connected = up
        lastError = up ? nil : reason
        guard up else { return }
        Task { await refreshSessions() }
        send(["type": "subscribeTrackedPrs"])
        send(["type": "subscribeChains"])
        send(["type": "subscribeHandoffs"])
        // A new connection is a new client id; the core re-sends `gridChange` for every owned grid.
        foreignGrid = [:]
        if let a = attachedTo { onGrid?(a.id, nil); attach(a.id, cols: a.cols, rows: a.rows) }
    }

    private func handle(type: String, data: Data) {
        struct Frame: Decodable {
            var sessionId: String?
            var session: SessionMeta?
            var state: SessionActivity?
            var data: String?
            var scrollback: String?
            var message: String?
            var tracked: [TrackedPrInfo]?
            var chains: [Chain]?
            var chain: Chain?
            var handoffs: [ChainHandoff]?
            var handoff: ChainHandoff?
            var slug: String?
            var owner: String?
            var cols: Int?
            var rows: Int?
        }
        guard let f = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        switch type {
        case "activity":
            if let id = f.sessionId, let state = f.state { activity[id] = state }
        case "created", "sessionMeta", "attached":
            if let meta = f.session {
                upsert(meta)
                if type == "created", awaitingCreate { awaitingCreate = false; onCreated?(meta.id) }
            }
            if type == "attached", let id = f.sessionId, let bytes = f.scrollback {
                onTerminalBytes?(id, Array(bytes.utf8))
            }
        case "output":
            if let id = f.sessionId, let bytes = f.data { onTerminalBytes?(id, Array(bytes.utf8)) }
        case "gridChange":
            guard let id = f.sessionId, let cols = f.cols, let rows = f.rows else { break }
            let foreign = f.owner != nil && f.owner != wire?.clientId
            foreignGrid[id] = foreign ? (cols, rows) : nil
            onGrid?(id, foreignGrid[id])
        case "exit":
            if let id = f.sessionId, let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].status = .exited
            }
        case "trackedPrs":
            trackedPrs = f.tracked ?? []
        case "chains":
            chains.replace(with: f.chains ?? [])
        case "chain":
            if let c = f.chain { chains.upsert(c) }
        case "handoffs":
            handoffs.replace(with: f.handoffs ?? [])
        case "handoff":
            if let h = f.handoff { handoffs.upsert(h) }
        case "chainRemoved":
            if let slug = f.slug { chains.remove(slug: slug) }
        case "error":
            lastError = f.message
            awaitingCreate = false
        default:
            break
        }
    }

    private func upsert(_ meta: SessionMeta) {
        if let i = sessions.firstIndex(where: { $0.id == meta.id }) { sessions[i] = meta } else { sessions.append(meta) }
    }
}
