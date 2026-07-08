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
    /// `SessionRegistry.resume` threw (e.g. the spawn failed).
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

/// Lazily revive an exited session: recover its `cliSessionId` when it predates
/// id capture, seed the persisted scrollback with a `── session resumed ──`
/// divider, and resume it through the registry. The one shared implementation of
/// the revive dance previously duplicated across `PrTrackingEngine.reactivate`,
/// `AppModel.reactivate`, and the WS `reactivate` handler (juancode-23m).
///
/// Returns the already-live session unchanged when one exists, so callers can
/// treat "make this session deliverable" as a single idempotent step.
/// `recoverId` is a seam for tests; it defaults to the real transcript scan
/// (`recoverCliSessionId`).
@discardableResult
public func reviveSession(
    _ id: String,
    registry: SessionRegistry,
    store: PersistentStore,
    cols: Int = 120,
    rows: Int = 32,
    recoverId: @escaping @Sendable (
        _ provider: ProviderId, _ cwd: String, _ createdAtMs: Int, _ excludeIds: Set<String>
    ) async -> String? = { await recoverCliSessionId($0, cwd: $1, createdAtMs: $2, excludeIds: $3) }
) async -> Result<Session, ReviveFailure> {
    if let live = registry.get(id) { return .success(live) }
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
    // Carry persisted scrollback into the revived session (with a separator
    // before the CLI repaints its TUI underneath).
    let prior = store.getScrollback(id) ?? []
    let seed: [UInt8] = prior.isEmpty ? [] : prior + Array(sessionResumedDivider.utf8)
    do {
        return .success(try registry.resume(meta, cols: cols, rows: rows, priorScrollback: seed))
    } catch {
        return .failure(.resumeFailed("\(error)"))
    }
}
