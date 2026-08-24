import Foundation
import JuancodeCore

/// What a `RemoteLiveSession` needs from the connection that owns it. Kept to the
/// frames one session drives, so the handle never reaches for the client's other
/// state and the two can be tested apart.
protocol RemoteSessionTransport: AnyObject, Sendable {
    /// Human name of the core, for error text ("the rust core").
    var backendName: String { get }
    func supports(_ capability: CoreCapability) -> Bool
    func sendInput(sessionId: String, text: String)
    /// Send a `resize`, returning the seq the matching `resizeAck` will carry.
    func sendResize(sessionId: String, cols: Int, rows: Int) -> Int
    func sendKill(sessionId: String)
    /// Write a row (and optionally its scrollback) into the desktop's mirror store.
    func persist(_ meta: SessionMeta, scrollback: [UInt8]?)
}

/// `LiveSession` over the wire: the same member set the terminal surfaces
/// subscribe to, answered from frames instead of from a pty this process owns.
///
/// Every member is one of three kinds, and which one it is matters more than the
/// code:
///
/// 1. A frame each way, so behaviour is the same as the in-process core: `write`
///    (`input`), `resizeLocal` (`resize`/`resizeAck`), `kill`, `onExit` (`exit`),
///    `onActivity` (`activity`), `getScrollback`/`subscribeOutput` (`attached` +
///    `output`).
/// 2. Degraded, because the operation is core-side by decision (juancode-ysjc) and
///    the connected core has not implemented it: `submit`/`insert`/`autoSubmit`
///    deliver a bracketed paste with no land check against the core's headless VT
///    model and therefore no retry, `kickQueue` is inert without the `queue`
///    capability, `markDormant` degrades to a kill, `setTitle`/`setArchived` write
///    the desktop's mirror row only.
/// 3. Absent by decision: `childPid` is nil for good — a pid from another process
///    is not addressable — which the one caller (agent-worktree detection) already
///    handles by falling back to the session cwd.
final class RemoteLiveSession: LiveSession, @unchecked Sendable {
    let id: String

    private let transport: RemoteSessionTransport
    private let lock = NSLock()

    private var storedMeta: SessionMeta
    private var storedActivity: SessionActivity = .idle
    private var running: Bool
    private var scrollback: [UInt8] = []
    private let scrollbackLimit: Int

    private var nextToken = 1
    private var outputListeners: [Int: OutputListener] = [:]
    private var exitListeners: [Int: ExitListener] = [:]
    private var activityListeners: [Int: ActivityListener] = [:]
    private var gridListeners: [Int: GridChangeListener] = [:]
    private var metaListeners: [Int: MetaChangeListener] = [:]

    /// The grid the core confirmed reached the pty, from `resizeAck.applied`.
    private var acked: (cols: Int, rows: Int)?
    /// The grid we last asked for, so an ack can be matched without a seq table.
    private var requested: (cols: Int, rows: Int)?
    /// Set when the core denied our last resize: another client owns the grid, so
    /// the next `resizeLocal` reports failure instead of pretending it took.
    private var deniedGrid = false
    /// `resizeAck.owner` / `gridChange.owner` when the core sends one, else nil.
    private var owner: String?
    /// Whether this connection is the owner, resolved against `serverInfo.clientId`.
    private let clientId: String?

    init(meta: SessionMeta, running: Bool, transport: RemoteSessionTransport,
         clientId: String?, scrollbackLimit: Int = Config.scrollbackLimit) {
        self.id = meta.id
        self.storedMeta = meta
        self.running = running
        self.transport = transport
        self.clientId = clientId
        self.scrollbackLimit = scrollbackLimit
    }

    // MARK: - Identity and state

    var meta: SessionMeta { lock.withLock { storedMeta } }
    var isRunning: Bool { lock.withLock { running } }
    var activity: SessionActivity { lock.withLock { storedActivity } }

    /// Nil for good on a remote core: a pid belongs to the process that forked it.
    var childPid: pid_t? { nil }

    // MARK: - Input

    func write(_ bytes: [UInt8]) { write(String(decoding: bytes, as: UTF8.self)) }

    func write(_ text: String) {
        guard !text.isEmpty else { return }
        transport.sendInput(sessionId: id, text: text)
    }

    /// Bracketed paste plus a separate CR, which is the *shape* of what the core's
    /// paste engine does but not the substance: the engine checks the pasted text
    /// landed in the CLI's input box against the headless VT model and retries when
    /// it did not, and that model lives in the core. So `.delivered` here means
    /// "written to the pty", not "verified in the prompt".
    func submit(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?) {
        paste(text, thenEnter: true, onResult: onResult)
    }

    func insert(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?) {
        paste(text, thenEnter: false, onResult: onResult)
    }

    /// NOT the path an opening prompt takes. A prompt belongs on the `create` frame,
    /// which is what reaches the core's verified engine; this is what is left for a
    /// caller that seeds a session it did not create, and it is worse in the way that
    /// matters. "The CLI has printed something" is the only "the TUI is up" signal
    /// available without the core's model, and it fires on the startup banner —
    /// seconds before the input box is interactive. There is no land check and no
    /// retry, so the prompt is typed into a booting TUI and the CR that follows is
    /// read by nobody: the agent sits with it unsent (the dispatch stall,
    /// juancode-t0vj).
    func autoSubmit(_ text: String, onResult: (@Sendable (AutoSubmitOutcome) -> Void)?) {
        guard !text.isEmpty else { onResult?(.submitted); return }
        waitForFirstOutput(timeout: 20) { [weak self] sawOutput in
            guard let self else { return }
            guard self.isRunning else {
                onResult?(.failed(reason: "the session exited before its prompt could be sent"))
                return
            }
            guard sawOutput else {
                onResult?(.failed(reason: "the \(self.transport.backendName) core printed nothing within 20s, so the prompt was not sent"))
                return
            }
            self.paste(text, thenEnter: true) { outcome in
                switch outcome {
                case .delivered: onResult?(.submitted)
                case .rejected(let reason), .aborted(let reason):
                    onResult?(.failed(reason: reason))
                }
            }
        }
    }

    /// Inert without the `queue` capability: there is no queue on the core to
    /// flush. Callers are gated in the UI; this stays a no-op rather than a throw
    /// because it is a hint, not an operation.
    func kickQueue() {
        guard transport.supports(.queue) else { return }
        // A core that grows the capability delivers on its own idle edge; there is
        // no `kickQueue` frame, and juancode-ysjc keeps it core-side.
    }

    // MARK: - Grid

    /// Optimistic by necessity: the answer only arrives in `resizeAck`, and this is
    /// called on every drag frame. Reports failure once the core has told us the
    /// grid is denied, which is the state the pane actually needs to know about.
    @discardableResult
    func resizeLocal(cols: Int, rows: Int) -> Bool {
        let denied: Bool = lock.withLock {
            requested = (cols, rows)
            return deniedGrid
        }
        _ = transport.sendResize(sessionId: id, cols: cols, rows: rows)
        return !denied
    }

    func appliedGrid() -> (cols: Int, rows: Int)? { lock.withLock { acked } }

    /// No `releaseGrid` frame exists (juancode-ysjc keeps it core-side), and a
    /// remote core releases our claims when the connection closes. Nothing to send.
    func releaseGrid(owner: String) {}

    func gridOwner() -> String? { lock.withLock { owner } }

    @discardableResult
    func onGridChange(_ listener: @escaping GridChangeListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = claimToken()
            gridListeners[t] = listener
            return t
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.gridListeners[token] = nil }
        }
    }

    // MARK: - Output

    func getScrollback() -> [UInt8] { lock.withLock { scrollback } }

    @discardableResult
    func subscribeOutput(replay: Bool, _ listener: @escaping OutputListener) -> Cancel {
        let (token, replayBytes): (Int, [UInt8]) = lock.withLock {
            let t = claimToken()
            outputListeners[t] = listener
            return (t, replay ? scrollback : [])
        }
        if !replayBytes.isEmpty { listener(replayBytes) }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.outputListeners[token] = nil }
        }
    }

    /// No model to seed from on this side, so this is the raw byte replay
    /// (`JUANCODE_RAW_REPLAY`'s path) rather than one clean screen.
    @discardableResult
    func subscribeFromModelSeed(_ onBytes: @escaping OutputListener) -> Cancel {
        subscribeOutput(replay: true, onBytes)
    }

    /// Re-emit what we hold. The width guard the in-process path applies compares
    /// the model's grid with the pane's; with no model there is nothing to compare,
    /// so a repaint is refused only when the core has confirmed a different grid.
    func repaintFromModel(matching grid: (cols: Int, rows: Int)?, _ onBytes: @escaping OutputListener) {
        let bytes: [UInt8]? = lock.withLock {
            if let grid, let acked, acked != grid { return nil }
            return scrollback
        }
        guard let bytes, !bytes.isEmpty else { return }
        onBytes(bytes)
    }

    // MARK: - Lifecycle and meta

    func kill() { transport.sendKill(sessionId: id) }

    /// There is no sleep frame on the wire (the Swift core serves it over REST), so
    /// this is a kill plus the dormant flag on the mirror row: the pty goes, the row
    /// stays resumable, which is what dormant means.
    /// The reason is a local diagnostic (it goes to the app's own activity log);
    /// a remote session can only ask the server to sleep it.
    func markDormant(reason: SessionSleepReason, audit: [String: String]) {
        markDormant()
    }

    func markDormant() {
        let (row, bytes) = lock.withLock { () -> (SessionMeta, [UInt8]) in
            storedMeta.dormant = true
            storedMeta.updatedAt = nowMs()
            return (storedMeta, scrollback)
        }
        transport.persist(row, scrollback: bytes)
        notifyMeta(row)
        transport.sendKill(sessionId: id)
    }

    /// Mirror-row only: the core owns its own row and has no frame to set a title
    /// through, so a pinned title is a desktop-side fact under the rust core.
    func setTitle(_ title: String) {
        let row = lock.withLock { () -> SessionMeta in
            storedMeta.title = title
            storedMeta.updatedAt = nowMs()
            return storedMeta
        }
        transport.persist(row, scrollback: nil)
        notifyMeta(row)
    }

    func setArchived(_ archived: Bool) {
        let row = lock.withLock { () -> SessionMeta in
            storedMeta.archived = archived
            storedMeta.updatedAt = nowMs()
            return storedMeta
        }
        transport.persist(row, scrollback: nil)
        notifyMeta(row)
    }

    @discardableResult
    func onExit(_ listener: @escaping ExitListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = claimToken()
            exitListeners[t] = listener
            return t
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.exitListeners[token] = nil }
        }
    }

    @discardableResult
    func onActivity(_ listener: @escaping ActivityListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = claimToken()
            activityListeners[t] = listener
            return t
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.activityListeners[token] = nil }
        }
    }

    /// Fires for edits this app made (a pinned title, an archive flip, going
    /// dormant) and, on a core that advertises `sessionMeta`, for the core's own
    /// edits. On a core without it the CLI-derived title never arrives here.
    @discardableResult
    func onMetaChange(_ listener: @escaping MetaChangeListener) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = claimToken()
            metaListeners[t] = listener
            return t
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.metaListeners[token] = nil }
        }
    }

    // MARK: - Frame intake (called by the client)

    func apply(attachedScrollback bytes: [UInt8], meta: SessionMeta) {
        let listeners: [OutputListener] = lock.withLock {
            scrollback = trimmed(bytes)
            storedMeta = meta
            running = meta.status == .running
            return Array(outputListeners.values)
        }
        // A late `attached` is a repaint of everything we know, which is what the
        // frame means when the core re-sends it after an overflow.
        if !bytes.isEmpty { for l in listeners { l(bytes) } }
        notifyMeta(meta)
    }

    func apply(output bytes: [UInt8]) {
        let listeners: [OutputListener] = lock.withLock {
            scrollback = trimmed(scrollback + bytes)
            return Array(outputListeners.values)
        }
        for l in listeners { l(bytes) }
    }

    func apply(meta: SessionMeta) {
        let changed: Bool = lock.withLock {
            guard storedMeta != meta else { return false }
            storedMeta = meta
            running = meta.status == .running
            return true
        }
        if changed { notifyMeta(meta) }
    }

    func apply(activity state: SessionActivity, notify: Bool) {
        let listeners: [ActivityListener] = lock.withLock {
            storedActivity = state
            if !running {
                // Activity for a session we thought was dead means the core has it
                // live: the desktop learned about it from a mirror row, not a frame.
                running = true
                storedMeta.status = .running
            }
            return Array(activityListeners.values)
        }
        for l in listeners { l(state, notify) }
    }

    func apply(exitCode: Int?) {
        let (listeners, row, bytes) = lock.withLock { () -> ([ExitListener], SessionMeta, [UInt8]) in
            running = false
            storedMeta.status = .exited
            storedMeta.exitCode = exitCode
            storedMeta.updatedAt = nowMs()
            return (Array(exitListeners.values), storedMeta, scrollback)
        }
        // Persist on the exit edge: nothing else writes the mirror's scrollback, so
        // this is where a finished session's transcript becomes searchable.
        transport.persist(row, scrollback: bytes)
        for l in listeners { l(exitCode) }
        notifyMeta(row)
    }

    func apply(resizeAck cols: Int, rows: Int, applied: Bool, denied: Bool, owner: String?) {
        let listeners: [GridChangeListener] = lock.withLock {
            deniedGrid = denied
            if let owner { self.owner = owner }
            guard applied else { return [] }
            acked = (cols, rows)
            return Array(gridListeners.values)
        }
        for l in listeners { l(owner ?? clientId, cols, rows) }
    }

    func apply(gridOwner owner: String?, cols: Int, rows: Int) {
        let listeners: [GridChangeListener] = lock.withLock {
            self.owner = owner
            deniedGrid = owner != nil && owner != clientId
            return Array(gridListeners.values)
        }
        for l in listeners { l(owner, cols, rows) }
    }

    /// The grid to (re)attach at: what the core confirmed, else what we asked for.
    var attachGrid: (cols: Int, rows: Int)? { lock.withLock { acked ?? requested } }

    /// Everything worth persisting when the app is going away.
    var snapshotForMirror: (meta: SessionMeta, scrollback: [UInt8]) {
        lock.withLock { (storedMeta, scrollback) }
    }

    // MARK: - Internals

    private func paste(_ text: String, thenEnter: Bool,
                       onResult: (@Sendable (PasteOutcome) -> Void)?) {
        guard isRunning else {
            onResult?(.aborted(reason: "the session is not running"))
            return
        }
        let spec = Providers.spec(for: meta.provider)
        let payload = spec.bracketedPaste ? "\u{1b}[200~\(text)\u{1b}[201~" : text
        transport.sendInput(sessionId: id, text: payload)
        guard thenEnter else { onResult?(.delivered); return }
        // A separate CR after a beat, like the in-process engine: the CLIs treat a
        // CR inside the paste as a newline in the box, not a submit.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            guard self.isRunning else {
                onResult?(.aborted(reason: "the session exited before the prompt was submitted"))
                return
            }
            self.transport.sendInput(sessionId: self.id, text: "\r")
            onResult?(.delivered)
        }
    }

    /// Resolve once the session has printed anything, or on timeout.
    private func waitForFirstOutput(timeout: TimeInterval,
                                    _ done: @escaping @Sendable (Bool) -> Void) {
        if !getScrollback().isEmpty { done(true); return }
        let fired = Latch()
        var cancel: Cancel?
        cancel = subscribeOutput(replay: false) { _ in
            guard fired.take() else { return }
            done(true)
        }
        let held = cancel
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            held?()
            guard fired.take() else { return }
            done(false)
        }
    }

    private func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > scrollbackLimit else { return bytes }
        return Array(bytes.suffix(scrollbackLimit))
    }

    private func notifyMeta(_ meta: SessionMeta) {
        let listeners = lock.withLock { Array(metaListeners.values) }
        for l in listeners { l(meta) }
    }

    /// Caller holds the lock.
    private func claimToken() -> Int {
        let token = nextToken
        nextToken += 1
        return token
    }
}

/// One-shot "did this already happen", for a wait that can be resolved by either
/// a frame or a timeout.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// True exactly once.
    func take() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}
