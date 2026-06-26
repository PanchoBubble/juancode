import Foundation
import JuancodeCore

/// Tracked-issue engine for juancode-z4v — the Linear twin of the tracked-PR engine
/// (`TrackedPr.swift`). Once a Linear issue is "tracked", a dedicated agent session
/// watches it and the poller diffs the issue's activity each tick.
///
/// The philosophy mirrors the PR tracker exactly: we do NOT reimplement anything.
/// The poller's only jobs are (1) detect *new* activity (comments, workflow-state
/// changes) via the real Linear GraphQL API, (2) classify each change as an obvious
/// next-step (auto) vs needs-a-human-decision, and (3) hand the work to the genuine
/// agent CLI by writing a prompt into its session, exactly as if the user typed it.
///
/// Classification is deliberately coarse and deterministic at this layer (the agent
/// makes the real call): new comments are auto next-steps; a move to a terminal
/// state (Done / Canceled) is a human gate → needs-decision; other state moves are
/// informational. The injected prompt re-states the do-or-escalate contract.
///
/// `TrackEvent` is shared with the PR tracker (it carries only human-readable
/// strings, so it's provider-agnostic).

// MARK: - state

/// What a tracked issue is currently doing, surfaced as a badge in the UI.
public enum IssueTrackState: String, Codable, Sendable {
    /// Open, nothing outstanding — just watching for new activity.
    case watching
    /// In a started workflow state (someone is actively working it).
    case active
    /// A change needs the user — the poller will NOT auto-apply it.
    case needsDecision
    /// Reached a terminal state (completed or canceled).
    case done
}

/// A surfaced decision the agent should not make autonomously.
public struct IssueTrackNotification: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var issueIdentifier: String
    public var message: String
    public var createdAt: Int
    public init(id: String, issueIdentifier: String, message: String, createdAt: Int) {
        self.id = id; self.issueIdentifier = issueIdentifier
        self.message = message; self.createdAt = createdAt
    }
}

/// The diffable baseline for one tracked issue: which comments we've already reacted
/// to, and the last workflow-state type we saw. `baselined` is false until the first
/// successful poll, so we don't fire events for activity that predates tracking.
public struct IssueTrackSnapshot: Sendable, Equatable, Codable {
    public var seenCommentIds: Set<String>
    public var stateType: String
    public var baselined: Bool

    public init(seenCommentIds: Set<String> = [], stateType: String = "", baselined: Bool = false) {
        self.seenCommentIds = seenCommentIds; self.stateType = stateType; self.baselined = baselined
    }
}

/// Result of classifying one poll: the advanced baseline + the events detected.
public struct IssueClassification: Sendable, Equatable {
    public var snapshot: IssueTrackSnapshot
    public var events: [TrackEvent]
    public init(snapshot: IssueTrackSnapshot, events: [TrackEvent]) {
        self.snapshot = snapshot; self.events = events
    }
}

/// One Linear issue under continuous watch: its identity, the agent session driving
/// work, the diff baseline, and any outstanding decisions. The badge `state` is
/// derived purely from the workflow state + open decisions.
public struct TrackedIssue: Sendable, Identifiable, Equatable, Codable {
    public var identifier: String
    public var title: String
    public var url: String
    public var cwd: String
    /// The agent session seeded with this issue's context, where prompts land.
    public var sessionId: String
    public var snapshot: IssueTrackSnapshot
    public var notifications: [IssueTrackNotification]
    public var lastPolledAt: Int?
    /// Last human-readable workflow-state name seen (for the badge label).
    public var lastStateName: String

    public init(identifier: String, title: String, url: String, cwd: String,
                sessionId: String, snapshot: IssueTrackSnapshot = .init(),
                notifications: [IssueTrackNotification] = [], lastPolledAt: Int? = nil,
                lastStateName: String = "") {
        self.identifier = identifier; self.title = title; self.url = url; self.cwd = cwd
        self.sessionId = sessionId; self.snapshot = snapshot; self.notifications = notifications
        self.lastPolledAt = lastPolledAt; self.lastStateName = lastStateName
    }

    public var id: String { TrackedIssue.key(cwd: cwd, identifier: identifier) }
    public static func key(cwd: String, identifier: String) -> String { "\(cwd)#\(identifier)" }

    public var state: IssueTrackState {
        deriveIssueTrackState(stateType: snapshot.stateType, hasOpenDecision: !notifications.isEmpty)
    }
}

// MARK: - classifier (pure)

/// Diff a freshly-polled `IssueActivity` against the prior baseline and classify what
/// changed. Pure and deterministic — the heart of the poller, unit-tested without any
/// network. The Linear twin of `classifyPrActivity`.
///
/// On the first poll (`!prev.baselined`) we only record the baseline and emit no
/// events, so tracking an already-active issue doesn't replay its whole history.
public func classifyIssueActivity(prev: IssueTrackSnapshot, activity: IssueActivity) -> IssueClassification {
    let allCommentIds = Set(activity.comments.map(\.id))
    let next = IssueTrackSnapshot(
        seenCommentIds: allCommentIds,
        stateType: activity.stateType,
        baselined: true)

    guard prev.baselined else {
        return IssueClassification(snapshot: next, events: [])
    }

    var events: [TrackEvent] = []

    let newComments = activity.comments.filter { !prev.seenCommentIds.contains($0.id) }
    if !newComments.isEmpty {
        let who = orderedUniqueAuthors(newComments.map(\.author))
        let n = newComments.count
        events.append(.autoFix("\(n) new comment\(n == 1 ? "" : "s")\(who.isEmpty ? "" : " from \(who)")"))
    }

    if prev.stateType != activity.stateType {
        let name = activity.stateName.isEmpty ? activity.stateType : activity.stateName
        switch activity.stateType {
        case "completed":
            events.append(.needsDecision("issue moved to \(name) (Done)"))
        case "canceled":
            events.append(.needsDecision("issue was canceled (\(name))"))
        default:
            break  // backlog / unstarted / started / triage moves are informational.
        }
    }

    return IssueClassification(snapshot: next, events: events)
}

// MARK: - derived UI state

/// Derive the badge state from the workflow-state type + outstanding decisions.
/// Deterministic so the UI is a pure function of the tracked issue's data.
public func deriveIssueTrackState(stateType: String, hasOpenDecision: Bool) -> IssueTrackState {
    if hasOpenDecision { return .needsDecision }
    switch stateType {
    case "completed", "canceled": return .done
    case "started": return .active
    default: return .watching
    }
}

// MARK: - prompt builders

/// The seed prompt handed to the tracking session when the user clicks "Track".
/// Establishes the issue context and the do-or-escalate contract once, up front.
public func trackIssueSeedPrompt(identifier: String, title: String, url: String) -> String {
    """
    [juancode issue-tracker] You are now tracking Linear issue \(identifier) "\(title)": \(url)

    I'll periodically tell you when there's new activity on this issue — new comments \
    or a change in its workflow state. When I do:
    - If it's an obvious next step (addressing a concrete comment, picking up clarified \
    requirements), do the work in this session.
    - If it needs a real decision (ambiguous feedback, the issue was closed or canceled, \
    or conflicting requirements), STOP and explain what you need from me instead of guessing.

    Start by reviewing issue \(identifier) and its description.
    """
}

/// The prompt injected mid-session when the poller detects new issue activity.
/// Summarises what changed and re-states the do-or-escalate contract.
public func issueActivityPrompt(identifier: String, reasons: [String]) -> String {
    let summary = reasons.isEmpty ? "new activity" : reasons.joined(separator: "; ")
    return """
    [juancode issue-tracker] New activity on \(identifier): \(summary). Re-check issue \
    \(identifier) — its latest comments and workflow state. If it's an obvious next step, \
    do it. If it needs a real decision, STOP and tell me what you need.
    """
}
