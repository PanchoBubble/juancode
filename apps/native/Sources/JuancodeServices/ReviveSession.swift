import Foundation
import JuancodeCore

/// Bringing an exited session back on the in-process Swift core: `reviveSession` and
/// the result types the WS handlers report it with.
///
/// Disposition (measured at this tree, juancode-880y): juancode-3s4p, inside the
/// juancode-nqpm commit. Every reader is `JuancodeServer` — six calls to
/// `reviveSession` (RegistryGlobalPause.swift:66, PrTrackingEngine.swift:230 and :450,
/// WebSocketConnection.swift:465, :670 and :744) plus `ReviveFailure.unresumable` at
/// WebSocketConnection.swift:476 — so it goes with them, together with
/// Tests/JuancodeServicesTests/ReviveSessionTests.swift. The one mention outside that
/// target, `JuancodeCore/RecoverSession.swift:296`, is a doc comment, not a caller.
/// `ResumeGrid.swift` is pinned in this target by the `resumeGrid(for:)` call at
/// line 119 below, and this deletion is what frees it to move under juancode-kf8n.

/// Divider appended after persisted scrollback when a session is revived, so the
/// carried-forward history is visually separated from the resumed CLI's repaint.
public let sessionResumedDivider = "\r\n\u{1B}[2m── session resumed ──\u{1B}[0m\r\n"

/// Why `reviveSession` couldn't bring an exited session back.
public enum ReviveFailure: Error, Sendable, Equatable {
    /// No persisted meta exists for the id.
    case notFound
    /// No prior CLI conversation id was captured or could be recovered from the
    /// CLI's own transcripts, so there is nothing to resume.
    case unresumable
    /// `SessionRegistry.resume` (or the fresh-boot fallback's `restartFresh`)
    /// threw — e.g. the spawn failed.
    case resumeFailed(String)

    /// Human-readable reason, phrased like the existing WS error frames.
    public var message: String {
        switch self {
        case .notFound:
            return "Session not found"
        case .unresumable:
            return "No prior CLI conversation could be found to resume this session."
        case let .resumeFailed(detail):
            return "Failed to resume: \(detail)"
        }
    }
}

/// How `reviveSession` brought a session back to life.
public enum Revival: Sendable {
    /// The prior CLI conversation resumed (or was already live).
    case resumed(Session)
    /// The pinned id had no transcript on disk (the session booted but never
    /// completed a turn), so a fresh conversation was booted in place instead.
    case startedFresh(Session)

    /// The live session either way.
    public var session: Session {
        switch self {
        case let .resumed(s), let .startedFresh(s): return s
        }
    }
}

/// Lazily revive an exited session: recover its `cliSessionId` when it predates
/// id capture, seed the persisted scrollback with a `── session resumed ──`
/// divider, and resume it through the registry. When the pinned id has no
/// transcript to resume (see `resumeNeedsFreshStart`), boots a fresh conversation
/// in place instead of running the doomed `--resume` — the same self-heal the
/// local `openPersistedPane` path does. The one shared implementation of the
/// revive dance previously duplicated across `PrTrackingEngine.reactivate`,
/// `AppModel.reactivate`, and the WS `reactivate` handler (juancode-23m).
///
/// Returns the already-live session unchanged when one exists, so callers can
/// treat "make this session deliverable" as a single idempotent step.
///
/// `cols`/`rows` are for callers that have a real viewport (a remote client's
/// `reactivate`). Leave them nil — the common case here, where the revive is driven
/// by a delivered message rather than a viewer — and the grid comes from
/// `resumeGrid(for:)`, the size the session's own surface last measured. A fixed
/// default was booting every message-driven revive at 120x32, and the CLI's
/// transcript reprint stayed wrapped for that grid in scrollback.
///
/// `recoverId` and `needsFreshStart` are seams for tests; they default to the
/// real transcript scans.
@discardableResult
public func reviveSession(
    _ id: String,
    registry: SessionRegistry,
    store: PersistentStore,
    cols: Int? = nil,
    rows: Int? = nil,
    recoverId: @escaping @Sendable (
        _ provider: ProviderId, _ cwd: String, _ createdAtMs: Int, _ excludeIds: Set<String>
    ) async -> String? = { await recoverCliSessionId($0, cwd: $1, createdAtMs: $2, excludeIds: $3) },
    needsFreshStart: @escaping @Sendable (SessionMeta) -> Bool = { resumeNeedsFreshStart($0) },
    log: SessionActivityLogging = NoopSessionActivityLog()
) async -> Result<Revival, ReviveFailure> {
    // Success outcomes are logged by the spawned Session itself (a "spawn" event
    // with mode resume/restartFresh); only the failure legs need logging here.
    func logFailure(_ failure: ReviveFailure, project: String) {
        log.log("reviveFailed", sessionId: id, project: project,
                fields: ["reason": failure.message])
    }
    if let live = registry.get(id) { return .success(.resumed(live)) }
    guard var meta = store.get(id) else {
        logFailure(.notFound, project: "")
        return .failure(.notFound)
    }
    // Old sessions predate id capture; try to recover it from the CLI's own
    // transcript so they can be resumed like newer ones.
    if meta.cliSessionId == nil {
        if let recovered = await recoverId(meta.provider, meta.cwd, meta.createdAt,
                                           store.usedCliSessionIds()) {
            store.setCliSessionId(id, cliSessionId: recovered)
            meta.cliSessionId = recovered
        }
    }
    guard meta.cliSessionId != nil else {
        logFailure(.unresumable, project: meta.cwd)
        return .failure(.unresumable)
    }
    let fallback = resumeGrid(for: meta)
    let g = (cols: cols ?? fallback.cols, rows: rows ?? fallback.rows)
    if needsFreshStart(meta) {
        do {
            return .success(.startedFresh(try registry.restartFresh(meta, cols: g.cols, rows: g.rows)))
        } catch {
            logFailure(.resumeFailed("\(error)"), project: meta.cwd)
            return .failure(.resumeFailed("\(error)"))
        }
    }
    // Carry persisted scrollback into the revived session (with a separator
    // before the CLI repaints its TUI underneath).
    let prior = store.getScrollback(id) ?? []
    let seed: [UInt8] = prior.isEmpty ? [] : prior + Array(sessionResumedDivider.utf8)
    do {
        return .success(.resumed(try registry.resume(meta, cols: g.cols, rows: g.rows, priorScrollback: seed)))
    } catch {
        logFailure(.resumeFailed("\(error)"), project: meta.cwd)
        return .failure(.resumeFailed("\(error)"))
    }
}
