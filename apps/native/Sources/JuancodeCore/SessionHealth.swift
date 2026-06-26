import Foundation

/// Health classification for a session, produced by the periodic health-check
/// sweep — pillar 3 of the orchestration loop (juancode-0me / juancode-02k).
///
/// Per-session `onExit` and live activity detection already exist; what was missing
/// is a periodic pass that *reconciles* the store against the live registry and
/// flags sessions that died or stalled so the UI can surface them and offer
/// reactivation. The brittle parts — the reconcile rules and the staleness
/// threshold — live here, pure and dependency-free, so they're unit-testable
/// without spinning up a real pty.
public enum SessionHealthState: String, Codable, Sendable, Equatable {
    /// Live and running normally.
    case healthy
    /// The pty process is gone. Either the store reports it `exited`, or the store
    /// still says `running` while the live registry no longer holds it — a
    /// crash/desync where the per-session `onExit` never fired. Offer reactivation.
    case dead
    /// Live and mid-turn (`busy`) but it hasn't emitted output for a long time — a
    /// likely hung turn. Surface it so the user can intervene.
    case stale
}

/// The slice of a session's state the classifier needs. Built by the app layer from
/// the persisted `SessionMeta` plus the live registry; kept minimal so the rules
/// stay testable in isolation.
public struct SessionHealthInput: Sendable, Equatable {
    public var id: String
    public var status: SessionStatus
    /// Whether the live registry currently holds this session (its pty is up).
    public var isLive: Bool
    /// Inferred live activity, nil for sessions that aren't live.
    public var activity: SessionActivity?
    /// ms-since-epoch of the session's last output / state change (`meta.updatedAt`,
    /// which advances on pty output and on exit).
    public var lastOutputMs: Int
    /// Whether a prior CLI conversation can be resumed (`cliSessionId != nil`).
    public var resumable: Bool

    public init(
        id: String,
        status: SessionStatus,
        isLive: Bool,
        activity: SessionActivity?,
        lastOutputMs: Int,
        resumable: Bool
    ) {
        self.id = id
        self.status = status
        self.isLive = isLive
        self.activity = activity
        self.lastOutputMs = lastOutputMs
        self.resumable = resumable
    }
}

/// An unhealthy session the sweep surfaced. `resumable` is carried through so the UI
/// knows whether to offer "Reactivate" (a dead, resumable session) vs. only "Go to".
public struct SessionHealthReport: Sendable, Equatable {
    public var id: String
    public var state: SessionHealthState
    public var resumable: Bool

    public init(id: String, state: SessionHealthState, resumable: Bool) {
        self.id = id
        self.state = state
        self.resumable = resumable
    }
}

public enum SessionHealth {
    /// A `busy` session that hasn't emitted output for this long is treated as a
    /// stalled turn. Generous (5 min) so a slow-but-working turn — a long build,
    /// a big file edit — isn't flagged; only genuinely wedged ones are.
    public static let defaultStaleBusyMs = 5 * 60 * 1000

    /// Classify a single session. Pure; `nowMs` and `staleBusyMs` are injected so
    /// tests pin the clock and threshold.
    public static func classify(
        _ s: SessionHealthInput, nowMs: Int, staleBusyMs: Int = defaultStaleBusyMs
    ) -> SessionHealthState {
        // Dead: the store says it exited, or it claims to be running but isn't in
        // the live registry (the pty died without `onExit` landing — a desync we'd
        // otherwise never notice).
        if s.status == .exited || !s.isLive { return .dead }
        // Stale: a turn that's been `busy` with no output past the budget. Idle /
        // waiting-input sessions are deliberately NOT flagged — that's the normal
        // "waiting for you" state, not a fault.
        if s.activity == .busy, nowMs - s.lastOutputMs >= staleBusyMs { return .stale }
        return .healthy
    }

    /// Classify a batch and return only the unhealthy sessions (state != `.healthy`),
    /// in input order. The app layer decides which sessions to feed in (e.g. only
    /// ones seen live this run) and how to surface the result.
    public static func sweep(
        _ inputs: [SessionHealthInput], nowMs: Int, staleBusyMs: Int = defaultStaleBusyMs
    ) -> [SessionHealthReport] {
        inputs.compactMap { s in
            let state = classify(s, nowMs: nowMs, staleBusyMs: staleBusyMs)
            guard state != .healthy else { return nil }
            return SessionHealthReport(id: s.id, state: state, resumable: s.resumable)
        }
    }
}
