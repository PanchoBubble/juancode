import Foundation
import JuancodeCore

/// One live session, as the UI is allowed to see it.
///
/// `CoreClient` used to hand the terminal surfaces a `JuancodeCore.Session`, the
/// real object holding the pty and the VT grid. A core in another process cannot
/// hand back an object, so the surfaces now hold this instead: the same members,
/// declared as a protocol, so a second implementation can answer them from wire
/// frames (`output`/`screen`/`activity`/`exit` in, `input`/`resize`/`kill` out)
/// while the in-process core keeps answering them by being the session.
///
/// Deliberately the exact member set the app already uses, no more: every one of
/// them has a call site in `JuancodeApp` today. `resizeGrid` is absent for that
/// reason. Only the embedded server arbitrates the shared grid, and it holds the
/// concrete `Session`.
///
/// Three members have no wire frame behind them yet, and are the residual
/// coupling a remote core has to close: `onMetaChange` (no meta-change frame,
/// only `created`/`attached` snapshots), `gridOwner`/`onGridChange`'s owner
/// (`resizeAck` carries applied/denied but never who owns the grid) and
/// `childPid` (a pid is meaningless across a process boundary anyway).
public protocol LiveSession: AnyObject, Sendable {

    /// Cancel handles and listener shapes, structurally identical to `Session`'s
    /// own so conformance is a no-op for the in-process core.
    typealias Cancel = @Sendable () -> Void
    typealias OutputListener = @Sendable (_ bytes: [UInt8]) -> Void
    typealias ExitListener = @Sendable (_ exitCode: Int?) -> Void
    typealias ActivityListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void
    typealias GridChangeListener = @Sendable (_ owner: String?, _ cols: Int, _ rows: Int) -> Void
    typealias MetaChangeListener = @Sendable (_ meta: SessionMeta) -> Void

    // MARK: - Identity and state (wire: created, attached, exit)

    /// The persisted row as the core last wrote it.
    var meta: SessionMeta { get }

    /// The session id, stable across a pty replacement.
    var id: String { get }

    /// Whether a pty is running right now.
    var isRunning: Bool { get }

    /// The current turn state, without waiting for the next `onActivity` edge.
    var activity: SessionActivity { get }

    /// The pty child's pid while running. Local-core only: nothing on the wire
    /// carries it, and a pid from another machine would not be addressable.
    var childPid: pid_t? { get }

    // MARK: - Input (wire: input, inputAck)

    /// Write raw bytes to the pty.
    func write(_ bytes: [UInt8])

    /// Write UTF-8 text to the pty.
    func write(_ text: String)

    /// Deliver `text` to the agent's prompt and press Enter, as a bracketed paste
    /// plus a separate CR with the land checks in between.
    func submit(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?)

    /// Same delivery as `submit` with no trailing Enter, so the user can edit it
    /// before sending.
    func insert(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?)

    /// Deliver an opening prompt once the CLI's input box exists, retrying the
    /// paste across the boot window.
    func autoSubmit(_ text: String, onResult: (@Sendable (AutoSubmitOutcome) -> Void)?)

    /// Flush the pending message queue now, rather than on the next idle edge.
    func kickQueue()

    // MARK: - Grid (wire: resize, resizeAck, screen)

    /// Claim the shared grid for the local pane and resize the pty to match.
    /// False when another client owns it.
    @discardableResult
    func resizeLocal(cols: Int, rows: Int) -> Bool

    /// The grid the pty actually runs at, or nil when it isn't live.
    func appliedGrid() -> (cols: Int, rows: Int)?

    /// Give up `owner`'s claim on the shared grid.
    func releaseGrid(owner: String)

    /// Who owns the shared grid, or nil when it is unclaimed.
    func gridOwner() -> String?

    /// Watch arbitrated grid changes: every granted resize and every real release.
    @discardableResult
    func onGridChange(_ listener: @escaping GridChangeListener) -> Cancel

    // MARK: - Output (wire: attached, output, screen)

    /// The session's scrollback as the core holds it.
    func getScrollback() -> [UInt8]

    /// Subscribe to the pty byte stream, optionally replaying the scrollback
    /// first. Returns a cancel handle.
    @discardableResult
    func subscribeOutput(replay: Bool, _ listener: @escaping OutputListener) -> Cancel

    /// Subscribe to the byte stream seeded from the headless VT model's current
    /// screen instead of the raw scrollback, so a fresh view paints one screen
    /// rather than replaying the whole history. Returns a cancel handle.
    @discardableResult
    func subscribeFromModelSeed(_ onBytes: @escaping OutputListener) -> Cancel

    /// Re-emit the model's current screen, dropped if the model has already moved
    /// off `grid`. The width guard is what keeps a repaint from being parsed at one
    /// grid and painted at another.
    func repaintFromModel(matching grid: (cols: Int, rows: Int)?,
                          _ onBytes: @escaping OutputListener)

    // MARK: - Lifecycle and meta (wire: kill, exit, activity)

    /// Terminate the pty.
    func kill()

    /// Put the session to sleep: kill the pty but keep the row resumable
    /// (REST `/api/sessions/:id/sleep`).
    func markDormant()

    /// Sleep it, saying which path decided and on what evidence — the fields land
    /// in `session-activity.log`. A requirement rather than only an extension so a
    /// local `Session` reached through this protocol still records the reason; the
    /// remote client, which has no log of its own, takes the default below.
    func markDormant(reason: SessionSleepReason, audit: [String: String])

    /// Pin a title, overriding the CLI-title poll.
    func setTitle(_ title: String)

    /// Archive or unarchive the session.
    func setArchived(_ archived: Bool)

    /// Watch for pty exit. Returns a cancel handle.
    @discardableResult
    func onExit(_ listener: @escaping ExitListener) -> Cancel

    /// Watch turn-state edges. Returns a cancel handle.
    @discardableResult
    func onActivity(_ listener: @escaping ActivityListener) -> Cancel

    /// Watch out-of-band meta edits: a derived title landing, a rename, an
    /// archive flip. Returns a cancel handle.
    @discardableResult
    func onMetaChange(_ listener: @escaping MetaChangeListener) -> Cancel
}

public extension LiveSession {
    /// Protocol requirements cannot carry default arguments, so the fire-and-forget
    /// forms `Session` gets for free are spelled out here.
    func submit(_ text: String) { submit(text, onResult: nil) }

    func insert(_ text: String) { insert(text, onResult: nil) }

    func autoSubmit(_ text: String) { autoSubmit(text, onResult: nil) }
}

/// The in-process core's session *is* the handle, so conformance is declarative.
/// Declared here rather than in `JuancodeCore` on purpose: the core should not
/// know about a client-side protocol, and this direction leaves it free to stay
/// the only implementation that can afford to be an object.
extension Session: LiveSession {}

// MARK: - Pane-pool erasure

/// The keep-alive pane pool (`LivePanePool`) keys each mounted pane by its session's
/// object identity, and its generic parameter is constrained to `AnyObject`, which
/// Swift will not let `any LiveSession` satisfy, class-constrained or not. So the
/// pool is parameterised on `AnyObject` and handles are re-typed on the way out.
/// Erasing a class-constrained existential to `AnyObject` yields the same reference,
/// so the pool's `===` and `ObjectIdentifier` still compare the sessions themselves
/// and pane identity is unchanged.
///
/// Relaxing `LivePanePool`'s constraint to an unconstrained parameter with `as
/// AnyObject` identity would delete this shim; it lives in `JuancodeCore`, so that
/// is a separate change.
public extension LivePanePool.Entry {
    /// The pooled handle, re-typed. Total in practice: the only thing ever pooled is
    /// a handle resolved through `CoreClient.liveSession`.
    var live: (any LiveSession)? { session as? any LiveSession }
}

public extension CoreClient {
    /// `liveSession` erased for the pane pool's `resolve` closures.
    func pooledSession(_ id: String) -> AnyObject? { liveSession(id) }
}
