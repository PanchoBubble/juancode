import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServices

/// The one way the SwiftUI app talks to a harness core.
///
/// The core is the non-UI half of juancode: it owns the ptys, the VT grid, the
/// persisted session rows, the per-session message queue, the tracked-PR watch
/// list, and the ephemeral editor/terminal ptys. That half runs in the `juancoded`
/// daemon (`RustCoreClient`), which is the only implementation since
/// juancode-nqpm; the protocol stays because the UI must not be able to tell where
/// the core runs, and because this is the seam that makes reaching past it into a
/// registry a compile error rather than a habit.
///
/// The surface is modelled on the WebSocket message set the wire speaks
/// (`JuancodeServer/WireProtocol.swift`) plus the REST endpoints the relay exposes.
/// That set is the contract, remote clients already depend on it, and re-deriving a
/// second vocabulary here would be a second contract to keep in sync. Each section
/// below names the wire messages it covers.
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

    // MARK: - Global pause (wire: pauseAll, resumeAll, pauseState)

    /// The set a global pause is holding asleep, shared by every surface this launch
    /// serves (juancode-tnxx).
    ///
    /// On the protocol so there is exactly one book per launch: the desktop's pause
    /// button and a `pauseAll` arriving over `/ws` from the phone both read and write
    /// this object, which is what makes a play from either surface revive the set the
    /// other one paused. It is not derived from `meta.dormant` — see `GlobalPauseBook`
    /// for why that set is too broad to play from.
    var globalPause: GlobalPauseBook { get }

    // MARK: - Session lifecycle (wire: create, reactivate, adoptExternal, setSkipPermissions, kill)

    /// Spawn a new agent session (wire `create`). Blocking: resolves the CLI
    /// through a login shell and forkpty()s, so callers keep it off the main actor.
    ///
    /// `initialInput` is an opening prompt for the core to *deliver*, not bytes to
    /// write: the core pastes it, confirms the paste is in the CLI's input box, and
    /// sends the submitting Enter separately once it is. Both cores implement that
    /// (`Session.autoSubmit`, the daemon's `deliver_seed`), and handing the text to
    /// `create` is the only thing that reaches them — a caller that instead calls
    /// `LiveSession.autoSubmit` on the returned session reaches the verified engine
    /// only in-process. On a remote core that call degrades to a paste plus a CR
    /// 120ms later, which arrives while the CLI is still booting, and the prompt is
    /// left typed and unsent with nothing running: the dispatch stall.
    ///
    /// `onSeedFailure` is `(sessionId, reason)` and fires only when a delivery did
    /// not submit. There is no success callback on purpose: the daemon reports a
    /// failed seed and says nothing about one that worked, so a success signal here
    /// would exist on one core and be invented on the other.
    ///
    /// `worktree` asks for isolation, and says who cut the tree — see
    /// `SessionWorktree`.
    @discardableResult
    func create(provider: ProviderId, cwd: String, cols: Int, rows: Int,
                opts: SpawnOptions, worktree: SessionWorktree?,
                dispatchId: String?, initialInput: String?,
                onSeedFailure: (@Sendable (String, String) -> Void)?) throws -> any LiveSession

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
    ///
    /// Unconfirmed: the return value is a row, not a receipt. On a core in this process
    /// those are the same thing; on a remote core they are not, and every caller that
    /// tells the user something happened must use `queueMessageConfirmed` instead.
    @discardableResult
    func queueMessage(_ sessionId: String, text: String) -> QueuedMessage

    /// Queue a message and do not return until the core has confirmed the row exists.
    ///
    /// The member every UI path uses, because the sync one above cannot fail on a
    /// remote core and therefore cannot tell the truth there: a fire-and-forget frame
    /// over a socket that may be down, addressed to a session the core may not have,
    /// carrying text the core may drop. Under the rust core all three of those read as
    /// success until juancode-rzl7, and "Send to agent" and "Submit review" cleared
    /// their baskets over messages the agent never received.
    ///
    /// Throws on a refusal AND on silence. A write nobody confirmed has not happened.
    func queueMessageConfirmed(_ sessionId: String, text: String) async throws -> QueuedMessage

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
    /// renders directly (wire `openEditor` / `editorReady`). `line` (1-based) puts
    /// the cursor there when the editor reads `+N`.
    func openEditorPty(cwd: String, file: String, line: Int?, cols: Int, rows: Int) throws -> EphemeralPty

    /// Open a login shell as an ephemeral pty for the bottom terminal panel
    /// (wire `openTerminal` / `terminalReady`).
    func openTerminalPty(cwd: String, cols: Int, rows: Int) throws -> EphemeralPty

    // MARK: - Tracked PRs (wire: subscribeTrackedPrs, trackPr, untrackPr, resolveTrackNotification)

    /// The current watch list, most recently polled first (wire `trackedPrs`).
    func trackedPrs() async -> [TrackedPr]

    /// Start tracking `pr`, spawning its driving agent session (wire `trackPr`).
    /// Nil when it is already tracked or the spawn failed.
    ///
    /// `adoptSessionId` tracks it in that existing session instead of spawning one —
    /// nothing is spawned and no worktree is made; nil also when that session can't
    /// be brought up or already drives another tracked PR.
    func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int,
                 adoptSessionId: String?) async -> TrackedPr?

    /// Stop tracking, leaving the agent session alone (wire `untrackPr`).
    func untrackPr(_ trackedId: String) async

    /// Dismiss a surfaced needs-decision escalation (wire `resolveTrackNotification`).
    func resolveTrackNotification(trackedId: String, notificationId: String) async

    /// Watch the tracked-PR registry (wire `subscribeTrackedPrs`). The subscriber is
    /// handed the current list immediately, exactly as the wire replies on
    /// subscribe. Returns a cancel handle.
    func subscribeTrackedPrs(
        _ onEvent: @escaping @Sendable (TrackedPrEvent) -> Void) async -> @Sendable () -> Void

    // MARK: - Heavy command queue (wire: heavyQueueSubscribe, heavySetPriority,
    //         heavySetSlots, heavyCancel)

    /// Watch the global `heavy` slot queue (wire `heavyQueueSubscribe`). The
    /// subscriber is handed the current queue as soon as the core answers, and the
    /// whole queue again on every change; replace wholesale. Returns a cancel handle,
    /// which also stops the core reading the registry when it is the last one.
    func subscribeHeavyQueue(
        _ onSnapshot: @escaping @Sendable (HeavyQueueSnapshot) -> Void) -> @Sendable () -> Void

    /// Move a job in line by rewriting its priority (wire `heavySetPriority`). Higher
    /// runs sooner; the waiting wrapper picks it up on its own next poll.
    func heavySetPriority(pid: Int, prio: Int)

    /// How many heavy jobs may run at once (wire `heavySetSlots`). Written into the
    /// wrapper's own config, so raising it lets jobs already in line through.
    func heavySetSlots(_ slots: Int)

    /// Stop a queued or running heavy job (wire `heavyCancel`).
    func heavyCancel(pid: Int)

    // MARK: - The GitHub surface (capability: github)

    /// The core's HTTP root, for the GitHub reads that are requests rather than
    /// subscriptions. Nil for a core with no HTTP surface of its own.
    ///
    /// On the protocol rather than only on the client that has one, because the reads
    /// it serves are the same reads the sidecar and the phone console make: one URL,
    /// three callers, and no second answer to "where does a PR list come from".
    var httpBaseURL: String? { get }

    /// A session's review — the cached one, or a fresh pass when `refresh` is true
    /// (wire `sessionReview` → `review`).
    ///
    /// Nil is "nothing has reviewed this", which is a different thing from a pass that
    /// found nothing and draws a different panel. A refresh is a whole model turn, so
    /// this can take minutes; it is off the socket's own task on the far side, so the
    /// panes on this connection keep painting while it runs.
    func review(sessionId: String, refresh: Bool) async throws -> ReviewPass?

    /// Stage an inline comment against a session's diff (wire `diffCommentAdd`).
    /// Answered with the whole list, because two surfaces stage against one session.
    @discardableResult
    func addDiffComment(sessionId: String, file: String, side: String, line: Int,
                        endLine: Int?, body: String, quote: String?,
                        commitSha: String?, commitSubject: String?)
        async throws -> [StagedDiffComment]

    /// Drop one staged comment, or — with no id — every one of the session's
    /// (wire `diffCommentDelete`).
    @discardableResult
    func removeDiffComments(sessionId: String, commentId: String?)
        async throws -> [StagedDiffComment]

    // MARK: - Launch state

    /// Sessions that were live when the previous process died or quit. Kept
    /// surfaced as sleeping rather than sunk with old dead rows.
    var crashOrphanIds: Set<String> { get }

    /// Of `crashOrphanIds`, the ones whose agent was mid-turn, which get the
    /// "Continue" offer on their restored pane.
    var midTurnOrphanIds: Set<String> { get }

    // MARK: - Working-tree changes (HTTP: /api/git/**, wire: session{Commit,Push,Revert,CommitMessage})

    /// The git working tree of a session's cwd. Every member is REQUIRED here rather
    /// than left in the extension beside its default, and that is not a style choice:
    /// a member that exists only in a protocol extension is dispatched STATICALLY, so
    /// a call through `any CoreClient` would reach the "this core cannot" default even
    /// on a core that implements it. The whole surface would be silently dead.
    ///
    /// `ChangesClient.swift` holds the defaults — all of them throw
    /// `CoreCapabilityError(.changes)` — and the doc comment for each.
    func diff(cwd: String) async throws -> DiffResult
    func baseDiff(cwd: String, base: String?) async throws -> BaseDiffResult
    func commitDiff(cwd: String, sha: String) async throws -> DiffResult
    func gitState(cwd: String) async throws -> GitState
    func recentCommits(cwd: String, limit: Int) async throws -> [RecentCommit]
    func worktrees(cwd: String) async throws -> [Worktree]
    func removeWorktree(path: String) async throws
    func worktreeStatus(cwd: String) async throws -> [WorktreeStatusEntry]
    func trackedFiles(cwd: String, limit: Int) async throws -> [String]
    func changeStat(cwd: String) async throws -> ChangeStat
    func readFile(cwd: String, path: String) async throws -> String
    func probeAtRisk(path: String) async throws -> AtRiskProbe?
    func agentWorktree(cwd: String, childPid: Int32) async throws -> String?
    func commitAll(sessionId: String, cwd: String?, message: String) async throws -> CommitResult
    func push(sessionId: String, cwd: String?) async throws -> PushResult
    func revert(sessionId: String, cwd: String?, path: String,
                hunkIndex: Int?) async throws -> RevertResult
    func draftCommitMessage(sessionId: String, cwd: String?) async throws -> String

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
    /// What a core with no `heavyQueue` capability does: nothing, visibly.
    ///
    /// Defaults rather than four no-op methods on every client, because the queue has
    /// exactly one implementation — the daemon that owns the registry — and a core
    /// without it has nothing to fall back to. The panel reads
    /// `unavailableReason(.heavyQueue)` and greys itself out with that sentence, so
    /// none of these is reached from a working build; they exist so a client is not
    /// forced to write a stub that would be a second answer to the same question.
    func subscribeHeavyQueue(
        _ onSnapshot: @escaping @Sendable (HeavyQueueSnapshot) -> Void) -> @Sendable () -> Void {
        onSnapshot(HeavyQueueSnapshot())
        return {}
    }

    func heavySetPriority(pid: Int, prio: Int) {}
    func heavySetSlots(_ slots: Int) {}
    func heavyCancel(pid: Int) {}

    /// What a core with no `github` capability does: refuse, by name.
    ///
    /// Thrown rather than silently answered with nil, for the reason
    /// `CoreCapabilityError` exists: a caller that reached a gated operation anyway is
    /// a UI bug, and an invented empty answer hides it. The panel reads
    /// `unavailableReason(.github)` and greys itself out with that sentence, so none of
    /// these is reached from a working build.
    var httpBaseURL: String? { nil }

    func review(sessionId: String, refresh: Bool) async throws -> ReviewPass? {
        throw CoreCapabilityError(.github, backend: info.daemon == nil ? "in-process" : "connected")
    }

    @discardableResult
    func addDiffComment(sessionId: String, file: String, side: String, line: Int,
                        endLine: Int?, body: String, quote: String?,
                        commitSha: String?, commitSubject: String?)
        async throws -> [StagedDiffComment] {
        throw CoreCapabilityError(.github, backend: info.daemon == nil ? "in-process" : "connected")
    }

    @discardableResult
    func removeDiffComments(sessionId: String, commentId: String?)
        async throws -> [StagedDiffComment] {
        throw CoreCapabilityError(.github, backend: info.daemon == nil ? "in-process" : "connected")
    }

    /// The GitHub reads, when this core has an HTTP surface to make them against.
    var github: GitHubReads? { httpBaseURL.map { GitHubReads(baseURL: $0) } }

    /// Track `pr` the default way: spawn a dedicated agent session for it.
    func trackPr(_ pr: PullRequest, cwd: String, cols: Int, rows: Int) async -> TrackedPr? {
        await trackPr(pr, cwd: cwd, cols: cols, rows: rows, adoptSessionId: nil)
    }

    /// Trail entries carrying no extra fields, matching `SessionActivityLogging`.
    func logSessionEvent(_ event: String, sessionId: String, project: String) {
        logSessionEvent(event, sessionId: sessionId, project: project, fields: [:])
    }
}

/// The worktree a `create` is to be isolated in, and which side cut it.
///
/// Which case a caller uses is not a preference: the tree has to belong to whichever
/// process owns the session row, because that row's `worktreePath` is the only thing
/// the delete-reap reads. A desktop that cut its own tree and handed the daemon the
/// path as a plain `cwd` left the daemon's row blank, so closing the session removed
/// nothing and the tree stayed on disk forever (juancode-asnn).
///
/// Only `.requested` is reachable now that the core is always another process. The
/// `.made` case survives as the thing `RustCoreClient` REFUSES: a caller that cuts
/// a tree itself and hands over the path gets an error rather than the silent leak
/// asnn was.
public enum SessionWorktree: Sendable, Equatable {
    /// A tree the CALLER already cut, by absolute path. No core accepts one: the row
    /// and the tree have to be made by the same process.
    case made(path: String)
    /// A tree the CORE must cut, as `<repo>-worktrees/<name>` off the create's `cwd`,
    /// on branch `juancode/<name>`.
    case requested(name: String)
}

/// A core's wire-protocol version and implemented capabilities: the `serverInfo`
/// handshake, available to the local UI on the same terms as a remote client.
public struct CoreServerInfo: Sendable, Equatable {
    public let protocolVersion: Int
    public let capabilities: [String]
    /// Who the core process is, when it is a separate one. Nil for an in-process
    /// core: it launched with this app and cannot be stale relative to it.
    public let daemon: DaemonIdentity?

    public init(protocolVersion: Int, capabilities: [String], daemon: DaemonIdentity? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.daemon = daemon
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

/// Why a queue write did not happen.
///
/// Its own error type rather than a `Bool` return, so a caller cannot ignore it by
/// accident: this exists because a queue write that had not happened used to answer
/// exactly like one that had (juancode-rzl7).
public struct QueueWriteError: LocalizedError {
    public let sessionId: String
    /// The core's own words when it refused, or ours when nothing answered at all.
    public let reason: String

    public init(sessionId: String, reason: String) {
        self.sessionId = sessionId
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public extension CoreClient {
    /// Confirmation for a core running in this process: `queueMessage` writes the row
    /// through the persistence it shares with the delivering session, so the row that
    /// comes back IS the confirmation and there is nothing to wait for. Overridden by
    /// `RustCoreClient`, where the core is another process and the answer is a frame.
    func queueMessageConfirmed(_ sessionId: String, text: String) async throws -> QueuedMessage {
        queueMessage(sessionId, text: text)
    }
}
