import Foundation
import JuancodeCore

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

/// Whether reviving `meta` must skip `--resume` and boot fresh instead: pinned-id
/// providers (Claude) write a transcript only once a turn completes, so a session
/// that booted but never finished a turn has nothing on disk and `--resume` would
/// just fast-exit into a dead pane. Discovered-id providers (Codex) only ever
/// capture an id from a transcript that exists, so they're never doomed this way.
/// The one shared pre-check behind `AppModel.reactivate` and `reviveSession`.
public func resumeNeedsFreshStart(_ meta: SessionMeta, roots: RecoverRoots = RecoverRoots()) -> Bool {
    guard Providers.spec(for: meta.provider).pinsSessionId,
          let cliId = meta.cliSessionId else { return false }
    return !claudeConversationExists(cliSessionId: cliId, cwd: meta.cwd, roots: roots)
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
/// `recoverId` and `needsFreshStart` are seams for tests; they default to the
/// real transcript scans.
@discardableResult
public func reviveSession(
    _ id: String,
    registry: SessionRegistry,
    store: PersistentStore,
    cols: Int = 120,
    rows: Int = 32,
    recoverId: @escaping @Sendable (
        _ provider: ProviderId, _ cwd: String, _ createdAtMs: Int, _ excludeIds: Set<String>
    ) async -> String? = { await recoverCliSessionId($0, cwd: $1, createdAtMs: $2, excludeIds: $3) },
    needsFreshStart: @escaping @Sendable (SessionMeta) -> Bool = { resumeNeedsFreshStart($0) }
) async -> Result<Revival, ReviveFailure> {
    if let live = registry.get(id) { return .success(.resumed(live)) }
    guard var meta = store.get(id) else { return .failure(.notFound) }
    // Old sessions predate id capture; try to recover it from the CLI's own
    // transcript so they can be resumed like newer ones.
    if meta.cliSessionId == nil {
        if let recovered = await recoverId(meta.provider, meta.cwd, meta.createdAt,
                                           store.usedCliSessionIds()) {
            store.setCliSessionId(id, cliSessionId: recovered)
            meta.cliSessionId = recovered
        }
    }
    guard meta.cliSessionId != nil else { return .failure(.unresumable) }
    if needsFreshStart(meta) {
        do {
            return .success(.startedFresh(try registry.restartFresh(meta, cols: cols, rows: rows)))
        } catch {
            return .failure(.resumeFailed("\(error)"))
        }
    }
    // Carry persisted scrollback into the revived session (with a separator
    // before the CLI repaints its TUI underneath).
    let prior = store.getScrollback(id) ?? []
    let seed: [UInt8] = prior.isEmpty ? [] : prior + Array(sessionResumedDivider.utf8)
    do {
        return .success(.resumed(try registry.resume(meta, cols: cols, rows: rows, priorScrollback: seed)))
    } catch {
        return .failure(.resumeFailed("\(error)"))
    }
}
