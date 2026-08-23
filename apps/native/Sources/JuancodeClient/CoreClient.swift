import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServices

/// The one way the SwiftUI app talks to a harness core.
///
/// The core is the non-UI half of juancode: it owns the ptys, the VT grid, the
/// persisted session rows, the per-session message queue, the tracked-PR watch
/// list, and the ephemeral editor/terminal ptys. Today that half runs in this
/// process (`SwiftCoreClient` over the in-process registry + store); the point of
/// this protocol is that the UI can no longer tell, so a second implementation
/// can front a core running somewhere else.
///
/// The surface is modelled on the WebSocket message set the embedded server
/// already speaks (`JuancodeServer/WireProtocol.swift`) plus the REST endpoints
/// the same server exposes. That set is the contract, remote clients already
/// depend on it, and re-deriving a second vocabulary here would be a second
/// contract to keep in sync. Each section below names the wire messages it
/// covers.
///
/// Nothing here hands back a core object. The live-session members return `any
/// LiveSession`, the per-session protocol the terminal surfaces subscribe to for
/// bytes, grid changes and activity, so a core in another process can answer them
/// from wire frames instead. `LiveSession` names the three members that still have
/// no frame behind them.
public protocol CoreClient: AnyObject, Sendable {

    // MARK: - Handshake (wire: serverInfo)

    /// Protocol version + capability list of the core behind this client, for the
    /// same feature detection remote clients do over `serverInfo`.
    var info: CoreServerInfo { get }

    // MARK: - Session lifecycle (wire: create, reactivate, adoptExternal, setSkipPermissions, kill)

    /// Spawn a new agent session (wire `create`). Blocking: resolves the CLI
    /// through a login shell and forkpty()s, so callers keep it off the main actor.
    @discardableResult
    func create(provider: ProviderId, cwd: String, cols: Int, rows: Int,
                opts: SpawnOptions, worktreePath: String?,
                dispatchId: String?) throws -> any LiveSession

    /// Spawn an editor session rooted in `parent`'s effective working directory.
    /// The in-app twin of the wire `openEditor`, which spawns an ephemeral pty
    /// instead of a session pane (see `openEditorPty`).
    @discardableResult
    func createEditorSession(parent: SessionMeta, file: String?, line: Int?,
                             cols: Int, rows: Int) throws -> any LiveSession

    /// Revive an exited session by resuming its prior CLI conversation
    /// (wire `reactivate`, and the tail of `adoptExternal`).
    @discardableResult
    func resume(_ meta: SessionMeta, cols: Int, rows: Int,
                priorScrollback: [UInt8]) throws -> any LiveSession

    /// Restart an exited session as a fresh conversation under the same id, for
    /// sessions with no transcript to resume.
    @discardableResult
    func restartFresh(_ meta: SessionMeta, cols: Int, rows: Int) throws -> any LiveSession

    /// Flip "accept all" on a live session (wire `setSkipPermissions`): the pty is
    /// replaced and the same conversation resumed at the new level.
    func setSkipPermissions(_ sessionId: String, skipPermissions: Bool,
                            cols: Int, rows: Int) async throws -> any LiveSession

    /// Terminate one session's pty (wire `kill`). No-op when it isn't live.
    func kill(_ sessionId: String)

    // MARK: - Live sessions (wire: created; per-session surface in `LiveSession`)

    /// The live handle for `id`, or nil when no pty is running for it.
    func liveSession(_ id: String) -> (any LiveSession)?

    /// Every session with a live pty right now.
    func liveSessions() -> [any LiveSession]

    /// Notify when any session goes live, whether created, resumed or restarted
    /// (wire `created`). Returns a cancel handle.
    @discardableResult
    func onSessionCreated(_ listener: @escaping (any LiveSession) -> Void) -> () -> Void

    // MARK: - Persisted sessions (REST: /api/sessions, /api/search)

    /// Every persisted session row, live or exited.
    func sessions() -> [SessionMeta]

    /// One persisted row, or nil when it was never persisted or has been pruned.
    func session(_ id: String) -> SessionMeta?

    /// Persist a new row (adopting an external conversation, re-inserting a row
    /// the retention cap pruned under an open pane).
    func insertSession(_ meta: SessionMeta)

    /// Overwrite a row's meta and scrollback together.
    func updateSession(_ meta: SessionMeta, scrollback: [UInt8])

    /// Hard-delete a row and everything hanging off it.
    func deleteSession(_ id: String)

    /// A session's persisted scrollback, or nil when nothing is stored.
    func storedScrollback(_ id: String) -> [UInt8]?

    /// Pin a session's title, overriding the CLI-title poll.
    func setTitle(_ id: String, title: String)

    /// Archive or unarchive a session row.
    func setArchived(_ id: String, archived: Bool)

    /// Record the resumable CLI conversation id recovered for a session.
    func setCliSessionId(_ id: String, cliSessionId: String)

    /// Every CLI conversation id juancode already owns: the exclusion set for
    /// external-session discovery, so one conversation is never adopted twice.
    func usedCliSessionIds() -> Set<String>

    /// Full-text search over persisted sessions (REST `/api/search`).
    func searchSessions(_ query: String, limit: Int) -> [SearchHit]

    /// Apply the per-project retention cap, never touching `keepIds`.
    func enforceSessionCap(projectKey: (String) -> String, keepIds: Set<String>)

    /// Compact the store (reclaim freelist pages, merge the FTS index). Blocking
    /// and lock-taking; callers run it off the startup path.
    func performMaintenance() throws -> GRDBStore.MaintenanceReport

    // MARK: - Message queue (wire: queueMessage, dequeueMessage, queue, subscribeQueue)

    /// Queue a message for delivery on the session's next idle edge.
    @discardableResult
    func queueMessage(_ sessionId: String, text: String) -> QueuedMessage

    /// A session's pending queue, in delivery order (wire `queue`).
    func queuedMessages(_ sessionId: String) -> [QueuedMessage]

    /// Cancel a still-pending queued message (wire `dequeueMessage`).
    @discardableResult
    func dequeueMessage(_ sessionId: String, messageId: String) -> Bool

    /// Watch a session's queue for changes (wire `subscribeQueue`); the listener is
    /// not called with the current snapshot. Returns a cancel handle.
    @discardableResult
    func subscribeQueue(_ sessionId: String,
                        _ listener: @escaping MessageQueue.Listener) -> @Sendable () -> Void

    // MARK: - Ephemeral ptys (wire: openEditor, openTerminal)

    /// Open a file in the configured editor as an ephemeral pty, which the overlay
    /// renders directly (wire `openEditor` / `editorReady`).
    func openEditorPty(cwd: String, file: String, cols: Int, rows: Int) throws -> EphemeralPty

    /// Open a login shell as an ephemeral pty for the bottom terminal panel
    /// (wire `openTerminal` / `terminalReady`).
    func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty

    // MARK: - Tracked PRs (wire: subscribeTrackedPrs, trackPr, untrackPr, resolveTrackNotification)

    /// The current watch list, most recently polled first (wire `trackedPrs`).
    func trackedPrs() async -> [TrackedPr]

    /// Start tracking `pr`, spawning its driving agent session (wire `trackPr`).
    /// Nil when it is already tracked or the spawn failed.
    func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int) async -> TrackedPr?

    /// Stop tracking, leaving the agent session alone (wire `untrackPr`).
    func untrackPr(_ trackedId: String) async

    /// Dismiss a surfaced needs-decision escalation (wire `resolveTrackNotification`).
    func resolveTrackNotification(trackedId: String, notificationId: String) async

    /// Watch the tracked-PR registry (wire `subscribeTrackedPrs`). The subscriber is
    /// handed the current list immediately, exactly as the wire replies on
    /// subscribe. Returns a cancel handle.
    func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void

    // MARK: - Launch state

    /// Sessions that were live when the previous process died or quit. Kept
    /// surfaced as sleeping rather than sunk with old dead rows.
    var crashOrphanIds: Set<String> { get }

    /// Of `crashOrphanIds`, the ones whose agent was mid-turn, which get the
    /// "Continue" offer on their restored pane.
    var midTurnOrphanIds: Set<String> { get }

    // MARK: - Presence, diagnostics, lifecycle

    /// Mark the desktop frontmost right now, so the core's push gate stays quiet
    /// while the user is at the desk (REST `/presence`).
    func markDesktopActive()

    /// Append to the durable session-lifecycle trail.
    func logSessionEvent(_ event: String, sessionId: String, project: String,
                         fields: [String: String])

    /// Flush the trail and report the file it lands in, for "reveal in Finder".
    func flushSessionLog() -> String

    /// Idle window, in minutes, before the reaper sleeps an idle session. `0`
    /// disables it.
    func setReaperIdleWindow(minutes: Int) async

    /// Sessions the reaper must never sleep, whatever the idle window or the
    /// live-session cap say: the pane the user has open and the active Oracle.
    /// Pushed from the UI on every change (and on its periodic tick, so no
    /// navigation path can leave the set stale).
    func setReaperProtectedIds(_ ids: Set<String>) async

    /// Force-kill every live pty (session + ephemeral).
    func shutdown()

    /// Put every live session to sleep and wait, bounded by `timeout`, for each
    /// pty to exit, so the CLI flushes its transcript before the process goes.
    /// Blocks the calling thread; call it off the main actor.
    func shutdownGracefully(timeout: TimeInterval)
}

public extension CoreClient {
    /// Trail entries carrying no extra fields, matching `SessionActivityLogging`.
    func logSessionEvent(_ event: String, sessionId: String, project: String) {
        logSessionEvent(event, sessionId: sessionId, project: project, fields: [:])
    }
}

/// A core's wire-protocol version and implemented capabilities: the `serverInfo`
/// handshake, available to the local UI on the same terms as a remote client.
public struct CoreServerInfo: Sendable, Equatable {
    public let protocolVersion: Int
    public let capabilities: [String]

    public init(protocolVersion: Int, capabilities: [String]) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    /// Whether the core implements a named capability (`"queue"`, `"screen"`, …).
    public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// A tracked-PR registry change: the two server messages a `subscribeTrackedPrs`
/// subscriber receives, as one value.
public enum TrackedPrEvent: Sendable {
    /// The complete watch list; replace wholesale (wire `trackedPrs`).
    case trackedPrs([TrackedPr])
    /// A single needs-decision escalation (wire `trackNotification`).
    case trackNotification(trackedId: String, prNumber: Int, notification: TrackNotification)
}
