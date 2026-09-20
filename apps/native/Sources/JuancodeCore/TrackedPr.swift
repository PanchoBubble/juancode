import Foundation

/// Tracked-PR engine for juancode-it5: once a PR is "tracked", a dedicated agent
/// session watches it and the poller diffs the PR's reviewable activity each tick.
///
/// The philosophy is the same as the rest of juancode — we do NOT reimplement the
/// reviewing/fixing logic. The poller's only jobs are (1) detect *new* activity
/// (comments, reviews, CI status) via the real `gh` CLI, (2) classify each change
/// as auto-fixable vs needs-a-human-decision, and (3) hand the work to the genuine
/// agent CLI by writing a prompt into its session, exactly as if the user typed
/// it. The agent then uses its own `gh`/`git` to read CI logs, amend, and push.
///
/// Classification is deliberately a coarse, deterministic heuristic at this layer
/// (the agent makes the real call): an explicit `CHANGES_REQUESTED` review is a
/// human gate → needs-decision; plain comments, `COMMENTED` reviews, and CI going
/// red → auto-fix attempts. The injected fix prompt itself instructs the agent to
/// stop and escalate if it hits genuine ambiguity.
///
/// Home (juancode-idza): `JuancodeCore`, because this is a wire DTO and not a port
/// question. `juancoded-core/src/pr.rs` holds the behaviour twin (`derive_track_state`,
/// `auto_fix_prompt`, `stalled_ci_fix_reason`) and `juancoded-server/src/tracked_prs.rs`
/// runs the engine, so what is left here is the shape the RUST path decodes into —
/// `RustCoreClient` reads `TrackedPr`, `PrTrackSnapshot` and `TrackNotification`,
/// `JuancodePersistence` stores them (`TrackedPrStore`, which used to be payload-only
/// precisely because it could not see this type), `JuancodeServer/WireProtocol.swift`
/// carries them and `JuancodeDesktop/LinearIssueTracker.swift` shares `TrackEvent`.
/// `JuancodeCore` is the only target all four can reach. `commentTaskPrompt` and
/// `diffReviewPrompt` have no Rust twin at all — they are the GitHub view's own.
///
/// The half that IS still a port question lives next to its argument types in
/// `JuancodeServices/PrTrackClassifier.swift`; the engine half that IS a fork is
/// `JuancodeServer/PrTrackingEngine.swift`, which juancode-nqpm deletes.

// MARK: - state

/// What a tracked PR is currently doing, surfaced as a badge in the UI.
public enum TrackState: String, Codable, Sendable {
    /// CI green / nothing outstanding — just watching for new activity.
    case watching
    /// CI is red or running, or new comments were just handed to the agent.
    case fixing
    /// A change needs the user — the poller will NOT auto-apply it.
    case needsDecision
}

/// A surfaced decision the agent should not make autonomously.
public struct TrackNotification: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var prNumber: Int
    public var message: String
    public var createdAt: Int
    public init(id: String, prNumber: Int, message: String, createdAt: Int) {
        self.id = id; self.prNumber = prNumber; self.message = message; self.createdAt = createdAt
    }
}

/// The diffable baseline for one tracked PR: which comments/reviews we've already
/// reacted to, and the last CI status we saw. `baselined` is false until the first
/// successful poll, so we don't fire events for activity that predates tracking.
public struct PrTrackSnapshot: Sendable, Equatable, Codable {
    public var seenCommentIds: Set<String>
    public var seenReviewIds: Set<String>
    public var checks: PrChecks
    public var baselined: Bool

    public init(seenCommentIds: Set<String> = [], seenReviewIds: Set<String> = [],
                checks: PrChecks = .none, baselined: Bool = false) {
        self.seenCommentIds = seenCommentIds; self.seenReviewIds = seenReviewIds
        self.checks = checks; self.baselined = baselined
    }
}

/// A classified change detected between two polls.
public enum TrackEvent: Sendable, Equatable {
    /// The agent should attempt this autonomously (with a human reason for the UI).
    case autoFix(String)
    /// Surface to the user; do NOT auto-apply.
    case needsDecision(String)
    /// The PR is no longer open (merged or closed) — stop tracking it.
    case closed(String)
}

/// Result of classifying one poll: the advanced baseline + the events detected.
public struct PrClassification: Sendable, Equatable {
    public var snapshot: PrTrackSnapshot
    public var events: [TrackEvent]
    public init(snapshot: PrTrackSnapshot, events: [TrackEvent]) {
        self.snapshot = snapshot; self.events = events
    }
}

/// One PR under continuous watch: its identity, the agent session driving fixes,
/// the diff baseline, and any outstanding decisions. The badge `state` is derived
/// purely from CI status + open decisions.
public struct TrackedPr: Sendable, Identifiable, Equatable, Codable {
    public var number: Int
    public var title: String
    public var branch: String
    public var url: String
    public var cwd: String
    /// The agent session seeded with this PR's context, where fix prompts land.
    public var sessionId: String
    /// The repo's `owner/name` — the identity an inbound webhook carries, which
    /// only knows the GitHub repo, never a local cwd. Resolved via `gh` when
    /// tracking starts; nil on records that predate it (backfilled on poll), so
    /// old persisted payloads keep decoding.
    public var repoNwo: String?
    public var snapshot: PrTrackSnapshot
    public var notifications: [TrackNotification]
    public var lastPolledAt: Int?

    public init(number: Int, title: String, branch: String, url: String, cwd: String,
                sessionId: String, repoNwo: String? = nil, snapshot: PrTrackSnapshot = .init(),
                notifications: [TrackNotification] = [], lastPolledAt: Int? = nil) {
        self.number = number; self.title = title; self.branch = branch; self.url = url
        self.cwd = cwd; self.sessionId = sessionId; self.repoNwo = repoNwo
        self.snapshot = snapshot
        self.notifications = notifications; self.lastPolledAt = lastPolledAt
    }

    public var id: String { TrackedPr.key(cwd: cwd, number: number) }
    public static func key(cwd: String, number: Int) -> String { "\(cwd)#\(number)" }

    public var state: TrackState {
        deriveTrackState(checks: snapshot.checks, hasOpenDecision: !notifications.isEmpty)
    }
}

/// Level-triggered recovery for a tracked PR whose CI is red with nobody on it.
///
/// `classifyPrActivity` is edge-triggered: it reports failing CI only on the
/// transition *into* `.failing`. That's right for "CI just broke", but it means a
/// PR whose driving session dies while CI is already red — an app restart SIGTERMs
/// it, or the reaper sleeps it once idle — is never worked again: every later poll
/// sees failing → failing, emits no event, and the revive/respawn ladder never
/// runs. So each poll also asks this: red CI must always have a live agent on it.
///
/// Yields nothing when the session is live (an agent already working the PR must
/// not be re-prompted every tick) or when the poll already produced fix work (that
/// prompt revives the session by itself).
public func stalledCiFixReason(checks: PrChecks, sessionLive: Bool,
                               hasPendingFixes: Bool) -> String? {
    guard checks == .failing, !sessionLive, !hasPendingFixes else { return nil }
    return "CI is still failing and the session that was working this PR is gone"
}

/// Comma-join distinct, non-empty `@author`s in first-seen order (for summaries).
/// `public` because the Linear issue tracker (`classifyIssueActivity`) shares it from
/// `JuancodeDesktop` — it used to be a same-module call.
public func orderedUniqueAuthors(_ logins: [String]) -> String {
    var seen = Set<String>()
    var out: [String] = []
    for l in logins where !l.isEmpty && seen.insert(l).inserted { out.append("@\(l)") }
    return out.joined(separator: ", ")
}

// MARK: - derived UI state

/// Derive the badge state from CI status + outstanding decisions. Deterministic so
/// the UI is a pure function of the tracked PR's data.
public func deriveTrackState(checks: PrChecks, hasOpenDecision: Bool) -> TrackState {
    if hasOpenDecision { return .needsDecision }
    switch checks {
    case .failing, .pending: return .fixing
    case .passing, .none: return .watching
    }
}

// MARK: - prompt builders

/// The prompt injected mid-session when the poller detects auto-fixable activity.
/// Summarises what changed and re-states the fix-or-escalate contract; the agent
/// reads the specifics itself via `gh`.
public func autoFixPrompt(number: Int, branch: String, reasons: [String]) -> String {
    let summary = reasons.isEmpty ? "new activity" : reasons.joined(separator: "; ")
    return """
    [juancode PR-tracker] New activity on PR #\(number): \(summary). \
    Check the latest state with `gh pr view \(number)`, `gh pr checks \(number)`, \
    and `gh pr diff \(number)`. If it's an obvious fix, make it, commit, and push \
    to `\(branch)`. If it needs a real decision, STOP and tell me what you need.
    """
}

/// The prompt queued into a session when the user clicks "Send to agent" on a
/// single review comment in the GitHub view. Carries the comment verbatim (the
/// agent shouldn't have to re-find it), the diff hunk it was left on when GitHub
/// gave us one — the reviewer's line numbers may have drifted since, so the code
/// itself is the reliable anchor — and asks for a threaded reply via `gh` once
/// addressed, so the reviewer sees it was handled.
public func commentTaskPrompt(number: Int, path: String?, line: Int?,
                              author: String, body: String, url: String,
                              diffHunk: String? = nil) -> String {
    let who = author.isEmpty ? "a reviewer" : "@\(author)"
    let location: String
    if let path {
        let at = line.map { "\(path):\($0)" } ?? path
        location = " on `\(at)`"
    } else {
        location = ""
    }
    var code = ""
    if let diffHunk, !diffHunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        code = """


        The code it was left on:

        ```diff
        \(diffHunk)
        ```
        """
    }
    return """
    [juancode GitHub view] Please address this review comment from \(who)\(location) \
    on PR #\(number):

    \(body)\(code)

    (\(url))

    If it's an obvious fix, make the change, commit, and push. If it needs a real \
    decision, STOP and tell me what you need. When you're done, reply on the comment \
    thread via `gh` explaining what you did.
    """
}

/// The prompt queued into a session when the user hands the staged diff-review
/// basket to the agent from the GitHub view's Diff tab. `feedback` is the composed
/// `composeReviewFeedback` block (numbered `file:line — note` entries with the
/// quoted diff lines); this wraps it with the PR pointer so the agent knows which
/// PR the notes are against.
public func diffReviewPrompt(number: Int, url: String, feedback: String) -> String {
    return """
    [juancode GitHub view] Diff review on PR #\(number) (\(url)):

    \(feedback)

    If a point is an obvious fix, make the change, commit, and push to the PR branch. \
    If any needs a real decision, STOP and tell me what you need.
    """
}
