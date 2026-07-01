import Foundation
import JuancodeCore

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
    public var snapshot: PrTrackSnapshot
    public var notifications: [TrackNotification]
    public var lastPolledAt: Int?

    public init(number: Int, title: String, branch: String, url: String, cwd: String,
                sessionId: String, snapshot: PrTrackSnapshot = .init(),
                notifications: [TrackNotification] = [], lastPolledAt: Int? = nil) {
        self.number = number; self.title = title; self.branch = branch; self.url = url
        self.cwd = cwd; self.sessionId = sessionId; self.snapshot = snapshot
        self.notifications = notifications; self.lastPolledAt = lastPolledAt
    }

    public var id: String { TrackedPr.key(cwd: cwd, number: number) }
    public static func key(cwd: String, number: Int) -> String { "\(cwd)#\(number)" }

    public var state: TrackState {
        deriveTrackState(checks: snapshot.checks, hasOpenDecision: !notifications.isEmpty)
    }
}

// MARK: - classifier (pure)

/// Diff a freshly-polled `PrActivity` against the prior baseline and classify what
/// changed. Pure and deterministic — the heart of the poller, unit-tested without
/// spawning anything.
///
/// On the first poll (`!prev.baselined`) we only record the baseline and emit no
/// events, so tracking an already-busy PR doesn't replay its whole history.
public func classifyPrActivity(prev: PrTrackSnapshot, activity: PrActivity) -> PrClassification {
    let allCommentIds = Set(activity.comments.map(\.id))
    let allReviewIds = Set(activity.reviews.map(\.id))
    let next = PrTrackSnapshot(
        seenCommentIds: allCommentIds,
        seenReviewIds: allReviewIds,
        checks: activity.checks,
        baselined: true)

    // A merged/closed PR is terminal — emit a single `closed` event (even before the
    // first baseline, so tracking an already-merged PR untracks immediately) and skip
    // all other classification; there's nothing left to auto-fix or decide on.
    if activity.state == "MERGED" || activity.state == "CLOSED" {
        let reason = activity.state == "MERGED"
            ? "PR was merged — stopped tracking" : "PR was closed — stopped tracking"
        return PrClassification(snapshot: next, events: [.closed(reason)])
    }

    guard prev.baselined else {
        return PrClassification(snapshot: next, events: [])
    }

    var events: [TrackEvent] = []

    let newComments = activity.comments.filter { !prev.seenCommentIds.contains($0.id) }
    if !newComments.isEmpty {
        let who = orderedUniqueAuthors(newComments.map(\.author))
        let n = newComments.count
        events.append(.autoFix("\(n) new comment\(n == 1 ? "" : "s")\(who.isEmpty ? "" : " from \(who)")"))
    }

    for r in activity.reviews where !prev.seenReviewIds.contains(r.id) {
        let who = r.author.isEmpty ? "a reviewer" : "@\(r.author)"
        switch r.state {
        case "CHANGES_REQUESTED":
            events.append(.needsDecision("\(who) requested changes"))
        case "COMMENTED":
            if !r.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.autoFix("New review from \(who)"))
            }
        default:
            break  // APPROVED / DISMISSED / PENDING — informational, no action.
        }
    }

    if prev.checks != .failing && activity.checks == .failing {
        events.append(.autoFix("CI checks are failing"))
    }

    // Codex normally does the code review before a PR is queued for merge. When it
    // posts that it's out of review capacity, Claude has to step in and review the PR
    // itself (see `trackSeedPrompt`), so surface that as its own auto-fix signal.
    let newReviews = activity.reviews.filter { !prev.seenReviewIds.contains($0.id) }
    let codexTappedOut = newComments.contains { isCodexReviewLimitNotice($0.body) }
        || newReviews.contains { isCodexReviewLimitNotice($0.body) }
    if codexTappedOut {
        events.append(.autoFix("Codex is out of review capacity — review the PR yourself, then `@mergifyio queue`"))
    }

    return PrClassification(snapshot: next, events: events)
}

/// True when a comment/review body is Codex reporting it couldn't review the PR
/// because it hit its usage limits — the signal for Claude to review it instead.
func isCodexReviewLimitNotice(_ body: String) -> Bool {
    body.range(of: "usage limits for code reviews", options: .caseInsensitive) != nil
}

/// Comma-join distinct, non-empty `@author`s in first-seen order (for summaries).
/// Shared with the Linear issue tracker (`classifyIssueActivity`).
func orderedUniqueAuthors(_ logins: [String]) -> String {
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

/// The seed prompt handed to the tracking session when the user clicks "Track".
/// Establishes the PR context and the auto-fix-vs-escalate contract once, up front.
public func trackSeedPrompt(number: Int, title: String, branch: String, url: String) -> String {
    """
    [juancode PR-tracker] You are now tracking pull request #\(number) "\(title)" \
    (branch `\(branch)`): \(url)

    I'll periodically tell you when there's new activity on this PR — new review \
    comments or a change in CI status. When I do:
    - If it's an obvious fix (a lint/format/type error, a clearly-correct test fix, \
    or addressing a concrete review comment), make the change, commit, and push to \
    `\(branch)`.
    - If it needs a real decision (ambiguous feedback, conflicting requirements, a \
    risky refactor, or a non-obvious failure), STOP and explain what you need from \
    me instead of guessing.

    Codex review fallback: this PR is normally code-reviewed by Codex, and only added \
    to the Mergify merge queue after that review. If you see a comment saying Codex has \
    reached its usage limits for code reviews (i.e. it couldn't review this PR), do the \
    code review yourself: read the full diff, post your review as a PR comment, and fix \
    anything clearly wrong per the rules above. Once your review is clean and CI is \
    green, add the PR to the Mergify queue by commenting `@mergifyio queue` on it. If \
    your review turns up something that needs a real decision, STOP and escalate to me \
    instead of queueing.

    Start by reviewing the PR and its diff with `gh pr view \(number)` and \
    `gh pr diff \(number)`.
    """
}

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
