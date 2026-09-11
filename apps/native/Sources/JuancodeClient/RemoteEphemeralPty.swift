import Foundation
import JuancodeCore
import JuancodeServices

/// The desktop half of an ephemeral pty that lives in the `juancoded` daemon.
///
/// The asymmetry this exists to absorb: `CoreClient.openTerminalPty` hands a pane a
/// live pty synchronously, and the wire cannot. `openTerminal` goes out, the shell is
/// forked in another process, and `terminalReady` comes back with the id — 257ms on
/// this machine before the child's first instruction, seconds under load. Blocking the
/// main thread on that would freeze the window for the whole spawn.
///
/// So the pty is handed back immediately and the id is bound when it lands. Everything
/// a pane does in between is held: the grid it sized itself to, the keystrokes of
/// somebody who started typing into a pane that looked ready, and a close that beat
/// the ack. On `bind` they go out in that order — grid first, because bytes typed into
/// the wrong width wrap wrong and never un-wrap.
///
/// An open that never lands is not left hanging: the coordinator expires it, and the
/// pane hears the same `exit` it would hear from a shell that quit.
final class RemoteEphemeralPty: EphemeralPtyBackend, @unchecked Sendable {
    /// What a pane may type into an unbound pty before the buffer stops growing. A
    /// held-open pane is one the user believes is a terminal, so a bound on what it
    /// can hold matters more than the last keystroke of a paste into a pty that is
    /// not there yet.
    private static let pendingInputLimit = 64 * 1024

    private let send: @Sendable ([String: Any]) -> Void

    private let lock = NSLock()
    /// The daemon's own id for this pty, once its ready frame has landed. Nil while
    /// the open is still in flight, which is what everything below branches on.
    private var remoteId: String?
    private var pendingInput: [UInt8] = []
    private var pendingGrid: (cols: Int, rows: Int)?
    private var pendingKill = false
    /// Set once the pty is over, from either end. A write after it is dropped rather
    /// than sent: the id names nothing in the daemon any more, and `input` for an
    /// unknown id is how a keystroke ends up in whatever session reuses it.
    private var gone = false

    init(send: @escaping @Sendable ([String: Any]) -> Void) {
        self.send = send
    }

    /// The open was answered: adopt the daemon's id and flush what the pane did while
    /// it was in flight.
    func bind(_ id: String) {
        let (grid, input, kill): ((cols: Int, rows: Int)?, [UInt8], Bool) = lock.withLock {
            guard !gone else { return (nil, [], false) }
            remoteId = id
            defer {
                pendingGrid = nil
                pendingInput = []
                pendingKill = false
            }
            return (pendingGrid, pendingInput, pendingKill)
        }
        if let grid {
            send(["type": "resize", "sessionId": id, "cols": grid.cols, "rows": grid.rows])
        }
        if !input.isEmpty {
            send(["type": "input", "sessionId": id, "data": String(decoding: input, as: UTF8.self)])
        }
        if kill { send(["type": "kill", "sessionId": id]) }
    }

    /// The pty is over — it exited, the open failed, or the socket went away with the
    /// daemon's children. Nothing more goes out under this id.
    func markGone() {
        lock.withLock {
            gone = true
            pendingInput = []
            pendingGrid = nil
            pendingKill = false
        }
    }

    func write(_ bytes: [UInt8]) {
        let target: String? = lock.withLock {
            guard !gone else { return nil }
            guard let remoteId else {
                if pendingInput.count + bytes.count <= Self.pendingInputLimit {
                    pendingInput.append(contentsOf: bytes)
                }
                return nil
            }
            return remoteId
        }
        guard let target else { return }
        send(["type": "input", "sessionId": target,
              "data": String(decoding: bytes, as: UTF8.self)])
    }

    /// Unarbitrated, like the daemon's own ephemeral resize: this pty belongs to one
    /// pane, so there is nobody to lose the grid to. A resize held for an unbound pty
    /// still reports that it reached one, because it will — the alternative is a
    /// sequenced surface re-asserting a size forever against a pty that does not exist
    /// yet.
    @discardableResult
    func resize(cols: Int, rows: Int) -> Bool {
        guard cols > 0, rows > 0 else { return false }
        let outcome: (target: String?, accepted: Bool) = lock.withLock {
            guard !gone else { return (nil, false) }
            guard let remoteId else {
                pendingGrid = (cols, rows)
                return (nil, true)
            }
            return (remoteId, true)
        }
        if let target = outcome.target {
            send(["type": "resize", "sessionId": target, "cols": cols, "rows": rows])
        }
        return outcome.accepted
    }

    func kill() {
        let target: String? = lock.withLock {
            guard !gone else { return nil }
            guard let remoteId else {
                pendingKill = true
                return nil
            }
            return remoteId
        }
        if let target { send(["type": "kill", "sessionId": target]) }
    }
}

/// Every ephemeral pty this connection has open in the daemon, and the two id spaces
/// they are addressed in.
///
/// A terminal is correlated on the `requestId` the client made up and the daemon
/// echoes, because a tab strip can open three shells at once and `terminalReady`
/// alone would not say which pane got which. An editor has no such field on the wire
/// — the Swift core never carried one and the Rust core would not invent it — so
/// editors bind in arrival order, which is exact for as long as the desktop opens one
/// at a time, and the daemon answers opens in the order it received them.
///
/// Once bound, a pty is just an id: `output` and `exit` for it arrive on the same
/// frames a session's do, which is why the routing here runs before the session
/// lookup in `RustCoreClient`.
final class RemoteEphemeralPtys: @unchecked Sendable {
    /// How long an open may stay unanswered before the pane is told it failed. Long
    /// enough for a cold `fork`+`exec` on a loaded machine (7.5s has been measured
    /// here), short enough that a pane does not sit there looking live forever.
    static let openTimeout: TimeInterval = 30

    private struct Pane {
        let pty: EphemeralPty
        let backend: RemoteEphemeralPty
    }

    private let send: @Sendable ([String: Any]) -> Void

    private let lock = NSLock()
    /// Opens still in flight, oldest first. Terminals carry the requestId they will be
    /// matched on; editors have none and are matched by position.
    private var pendingTerminals: [(requestId: String, pane: Pane)] = []
    private var pendingEditors: [Pane] = []
    private var live: [String: Pane] = [:]

    init(send: @escaping @Sendable ([String: Any]) -> Void) {
        self.send = send
    }

    func openTerminal(cwd: String, cols: Int, rows: Int) -> EphemeralPty {
        let requestId = UUID().uuidString.lowercased()
        let pane = makePane(id: requestId)
        lock.withLock { pendingTerminals.append((requestId, pane)) }
        send(["type": "openTerminal", "cwd": cwd, "cols": cols, "rows": rows,
              "requestId": requestId])
        expireTerminal(requestId)
        return pane.pty
    }

    func openEditor(cwd: String, file: String, cols: Int, rows: Int) -> EphemeralPty {
        let pane = makePane(id: UUID().uuidString.lowercased())
        lock.withLock { pendingEditors.append(pane) }
        send(["type": "openEditor", "cwd": cwd, "file": file, "cols": cols, "rows": rows])
        expireEditor(pane)
        return pane.pty
    }

    /// The pty a pane holds is named by the client's own id, not the daemon's. The
    /// daemon's id is the backend's business, and nothing above this needs to know
    /// there are two.
    private func makePane(id: String) -> Pane {
        let backend = RemoteEphemeralPty(send: send)
        return Pane(pty: EphemeralPty(id: id, backend: backend), backend: backend)
    }

    func bindTerminal(requestId: String, terminalId: String) {
        let pane: Pane? = lock.withLock {
            guard let i = pendingTerminals.firstIndex(where: { $0.requestId == requestId })
            else { return nil }
            let p = pendingTerminals.remove(at: i).pane
            live[terminalId] = p
            return p
        }
        pane?.backend.bind(terminalId)
    }

    func bindEditor(editorId: String) {
        let pane: Pane? = lock.withLock {
            guard !pendingEditors.isEmpty else { return nil }
            let p = pendingEditors.removeFirst()
            live[editorId] = p
            return p
        }
        pane?.backend.bind(editorId)
    }

    /// Whether `id` is one of these rather than a session, which is what the `output`
    /// and `exit` handlers ask before they reach for a session handle.
    func holds(_ id: String) -> Bool { lock.withLock { live[id] != nil } }

    /// Route output; false when the id is not one of ours.
    func output(_ id: String, bytes: [UInt8]) -> Bool {
        guard let pane = lock.withLock({ live[id] }) else { return false }
        pane.pty.receive(bytes)
        return true
    }

    /// Route an exit; false when the id is not one of ours.
    func exited(_ id: String, code: Int?) -> Bool {
        guard let pane = lock.withLock({ live.removeValue(forKey: id) }) else { return false }
        close(pane, exitCode: code)
        return true
    }

    /// An `openTerminal` the daemon refused. The error frame carries no requestId — it
    /// has no session to name either — so the oldest unanswered open is the one that
    /// failed, which is exact whenever one is in flight and the best available
    /// otherwise.
    func failOldestTerminal(reason: String) {
        let pane: Pane? = lock.withLock {
            pendingTerminals.isEmpty ? nil : pendingTerminals.removeFirst().pane
        }
        guard let pane else { return }
        NSLog("juancode: the core refused a terminal pane: \(reason)")
        close(pane, exitCode: nil)
    }

    func failOldestEditor(reason: String) {
        let pane: Pane? = lock.withLock {
            pendingEditors.isEmpty ? nil : pendingEditors.removeFirst()
        }
        guard let pane else { return }
        NSLog("juancode: the core refused an editor pane: \(reason)")
        close(pane, exitCode: nil)
    }

    /// The socket went away. The daemon's ephemeral ptys are per connection and die
    /// with it, so every pane here is already over whether or not it has heard an
    /// `exit` — and a reconnect would put these ids in somebody else's id space.
    func closeAll(reason: String) {
        let panes: [Pane] = lock.withLock {
            let all = pendingTerminals.map(\.pane) + pendingEditors + Array(live.values)
            pendingTerminals = []
            pendingEditors = []
            live = [:]
            return all
        }
        if !panes.isEmpty {
            NSLog("juancode: \(panes.count) ephemeral pane(s) ended with the connection: \(reason)")
        }
        for pane in panes { close(pane, exitCode: nil) }
    }

    private func close(_ pane: Pane, exitCode: Int?) {
        pane.backend.markGone()
        pane.pty.finish(exitCode: exitCode)
    }

    private func expireTerminal(_ requestId: String) {
        Task { [weak self] in
            await Nap.ms(Int(Self.openTimeout * 1000))
            guard let self else { return }
            let pane: Pane? = lock.withLock {
                guard let i = pendingTerminals.firstIndex(where: { $0.requestId == requestId })
                else { return nil }
                return pendingTerminals.remove(at: i).pane
            }
            guard let pane else { return }
            NSLog("juancode: no terminalReady for \(requestId) within \(Int(Self.openTimeout))s")
            close(pane, exitCode: nil)
        }
    }

    private func expireEditor(_ pane: Pane) {
        Task { [weak self] in
            await Nap.ms(Int(Self.openTimeout * 1000))
            guard let self else { return }
            let expired: Bool = lock.withLock {
                guard let i = pendingEditors.firstIndex(where: { $0.pty === pane.pty })
                else { return false }
                pendingEditors.remove(at: i)
                return true
            }
            guard expired else { return }
            NSLog("juancode: no editorReady within \(Int(Self.openTimeout))s")
            close(pane, exitCode: nil)
        }
    }
}
