import Foundation
import JuancodeCore
import JuancodeServices

/// Linear GraphQL access for the tracked-issue engine (juancode-z4v). The twin of
/// the `gh`-shelling functions in `Gh.swift`, but Linear has no CLI so we talk to
/// the GraphQL API over HTTPS instead.
///
/// Faithful to juancode's "inherit the user's env untouched" principle, the API key
/// is read from the environment — never hardcoded or persisted. We honour
/// `JUANCODE_LINEAR_TOKEN` first (the project-specific override, matching
/// `JUANCODE_*_BIN`) then the conventional `LINEAR_API_KEY`.

private let LINEAR_GRAPHQL_URL = URL(string: "https://api.linear.app/graphql")!

/// The Linear personal API key from the environment, or nil when none is set (the
/// poller treats nil like a failed poll — it just skips this tick).
public func linearToken(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    for key in ["JUANCODE_LINEAR_TOKEN", "LINEAR_API_KEY"] {
        if let v = env[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
    }
    return nil
}

// MARK: - activity model (mirrors PrActivity)

/// One Linear comment. `author` is the commenter's display name (may be empty for
/// integration/bot comments without a user).
public struct IssueComment: Sendable, Equatable {
    public let id: String
    public let author: String
    public let body: String
    public init(id: String, author: String, body: String) {
        self.id = id; self.author = author; self.body = body
    }
}

/// A snapshot of a Linear issue's trackable activity: its workflow state (name +
/// type, e.g. "Ongoing"/"started", "Done"/"completed") and comments. What the
/// tracked-issue poller diffs each tick to detect new events.
public struct IssueActivity: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let url: String
    public let stateName: String
    public let stateType: String
    public let assignee: String
    public let comments: [IssueComment]
    public init(identifier: String, title: String, url: String, stateName: String,
                stateType: String, assignee: String, comments: [IssueComment]) {
        self.identifier = identifier; self.title = title; self.url = url
        self.stateName = stateName; self.stateType = stateType
        self.assignee = assignee; self.comments = comments
    }
}

// MARK: - raw GraphQL decode

private struct RawState: Decodable { var name: String?; var type: String? }
private struct RawUser: Decodable { var displayName: String? }
private struct RawComment: Decodable { var id: String?; var body: String?; var user: RawUser? }
private struct RawComments: Decodable { var nodes: [RawComment]? }
private struct RawIssue: Decodable {
    var identifier: String?
    var title: String?
    var url: String?
    var state: RawState?
    var assignee: RawUser?
    var comments: RawComments?
}
private struct RawIssueData: Decodable { var issue: RawIssue? }

/// Map Linear's `{ "data": { "issue": {...} } }` envelope onto our wire shape.
/// Exposed for testing. Returns nil when the issue is absent or has no identifier
/// (so the poller treats it as a failed tick). Drops comments missing an `id`.
func parseIssueActivity(_ raw: RawIssueForTest) -> IssueActivity? {
    guard let issue = raw.data?.issue, let identifier = issue.identifier else { return nil }
    return IssueActivity(
        identifier: identifier,
        title: issue.title ?? "",
        url: issue.url ?? "",
        stateName: issue.state?.name ?? "",
        stateType: issue.state?.type ?? "",
        assignee: issue.assignee?.displayName ?? "",
        comments: (issue.comments?.nodes ?? []).compactMap { c in
            guard let id = c.id else { return nil }
            return IssueComment(id: id, author: c.user?.displayName ?? "", body: c.body ?? "")
        })
}

/// Test seam mirroring the GraphQL envelope (so `parseIssueActivity` can be tested
/// against the exact JSON Linear emits, without a network call).
public struct RawIssueForTest: Decodable {
    fileprivate var data: RawIssueData?
}

private let ISSUE_QUERY = """
query($id:String!){ issue(id:$id){ identifier title url state{name type} \
assignee{displayName} comments(first:100){nodes{id body user{displayName}}} } }
"""

/// Read a single Linear issue's trackable activity via the GraphQL API. Returns nil
/// when no token is set, the network/HTTP fails, or the output won't parse — the
/// poller treats nil as "couldn't poll this tick" and tries again later. `identifier`
/// is the human id like "ENG-123" (Linear's `issue(id:)` resolves it directly).
public func getIssueActivity(_ identifier: String,
                             env: [String: String] = ProcessInfo.processInfo.environment) async -> IssueActivity? {
    guard let token = linearToken(env) else { return nil }
    var req = URLRequest(url: LINEAR_GRAPHQL_URL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Personal API keys go in the Authorization header verbatim (no "Bearer ").
    req.setValue(token, forHTTPHeaderField: "Authorization")
    let payload: [String: Any] = ["query": ISSUE_QUERY, "variables": ["id": identifier]]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    req.httpBody = body
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let raw = try JSONDecoder().decode(RawIssueForTest.self, from: data)
        return parseIssueActivity(raw)
    } catch {
        return nil
    }
}

// MARK: - assigned issues (for the "track an issue" picker, juancode-7sa)

/// A lightweight summary of one of the viewer's assigned Linear issues, used to
/// populate the "pick from assigned issues" affordance when starting tracking.
public struct IssueSummary: Sendable, Equatable, Identifiable {
    public let identifier: String
    public let title: String
    public let url: String
    public let stateName: String
    public let stateType: String
    public init(identifier: String, title: String, url: String, stateName: String, stateType: String) {
        self.identifier = identifier; self.title = title; self.url = url
        self.stateName = stateName; self.stateType = stateType
    }
    public var id: String { identifier }
}

private struct RawAssignedIssue: Decodable {
    var identifier: String?; var title: String?; var url: String?; var state: RawState?
}
private struct RawAssignedNodes: Decodable { var nodes: [RawAssignedIssue]? }
private struct RawViewer: Decodable { var assignedIssues: RawAssignedNodes? }
private struct RawViewerData: Decodable { var viewer: RawViewer? }

/// Test seam mirroring the `{ "data": { "viewer": { "assignedIssues": … } } }` envelope.
public struct RawAssignedForTest: Decodable {
    fileprivate var data: RawViewerData?
}

/// Map Linear's viewer→assignedIssues envelope onto `IssueSummary`. Pure and testable.
/// Drops issues missing an identifier and any already in a terminal (completed /
/// canceled) state — you don't start *tracking* finished work.
func parseAssignedIssues(_ raw: RawAssignedForTest) -> [IssueSummary] {
    (raw.data?.viewer?.assignedIssues?.nodes ?? []).compactMap { i in
        guard let identifier = i.identifier else { return nil }
        let type = i.state?.type ?? ""
        if type == "completed" || type == "canceled" { return nil }
        return IssueSummary(identifier: identifier, title: i.title ?? "", url: i.url ?? "",
                            stateName: i.state?.name ?? "", stateType: type)
    }
}

private let ASSIGNED_QUERY = """
query{ viewer{ assignedIssues(first:50){ nodes{ identifier title url state{name type} } } } }
"""

/// List the viewer's assigned, non-terminal Linear issues for the tracking picker.
/// Returns `[]` when no token is set or the call fails — the UI just shows "none".
public func getAssignedIssues(env: [String: String] = ProcessInfo.processInfo.environment) async -> [IssueSummary] {
    guard let token = linearToken(env) else { return [] }
    var req = URLRequest(url: LINEAR_GRAPHQL_URL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(token, forHTTPHeaderField: "Authorization")
    guard let body = try? JSONSerialization.data(withJSONObject: ["query": ASSIGNED_QUERY]) else { return [] }
    req.httpBody = body
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        let raw = try JSONDecoder().decode(RawAssignedForTest.self, from: data)
        return parseAssignedIssues(raw)
    } catch {
        return []
    }
}

// MARK: - assigned tickets, paged (the right rail's Tickets panel)

/// One of the viewer's assigned issues as the Tickets panel lists it. Codable so the
/// panel can keep the last page across a relaunch instead of refetching.
public struct LinearTicket: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let identifier: String
    public let title: String
    public let url: String
    /// 0 none, 1 urgent, 2 high, 3 medium, 4 low (Linear's numbering).
    public let priority: Int
    public let stateName: String
    public let stateType: String
    /// The workflow state's colour, "#rrggbb".
    public let stateColor: String
    public let teamKey: String
    public let branchName: String
    public let updatedAt: Date?

    public init(id: String, identifier: String, title: String, url: String, priority: Int,
                stateName: String, stateType: String, stateColor: String, teamKey: String,
                branchName: String, updatedAt: Date?) {
        self.id = id; self.identifier = identifier; self.title = title; self.url = url
        self.priority = priority; self.stateName = stateName; self.stateType = stateType
        self.stateColor = stateColor; self.teamKey = teamKey; self.branchName = branchName
        self.updatedAt = updatedAt
    }
}

/// Which workflow states the panel shows. Filtered server-side, so a page of ten is
/// ten matching tickets rather than ten that are then thinned out.
public enum LinearTicketScope: String, CaseIterable, Identifiable, Sendable {
    case open, inProgress, todo, backlog, done
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .todo: "Todo"
        case .backlog: "Backlog"
        case .done: "Done"
        }
    }

    /// The `state.type` comparator for this scope.
    var stateType: [String: [String]] {
        switch self {
        case .open: ["nin": ["completed", "canceled"]]
        case .inProgress: ["in": ["started"]]
        case .todo: ["in": ["unstarted"]]
        case .backlog: ["in": ["backlog", "triage"]]
        case .done: ["in": ["completed", "canceled"]]
        }
    }
}

public struct LinearTicketPage: Sendable, Equatable {
    public let tickets: [LinearTicket]
    public let hasNextPage: Bool
    public let endCursor: String?
}

public enum LinearTicketsError: Error, Equatable, Sendable {
    case noToken
    case failed(String)

    public var message: String {
        switch self {
        case .noToken: "Set LINEAR_API_KEY (or JUANCODE_LINEAR_TOKEN) in your shell environment, then relaunch."
        case .failed(let m): m
        }
    }
}

/// The `IssueFilter` for a scope plus the search box. A query shaped like an issue id
/// ("ENG-42") also matches that issue by team key and number, since titles rarely
/// contain their own identifier.
func linearTicketFilter(scope: LinearTicketScope, search: String) -> [String: Any] {
    var filter: [String: Any] = ["state": ["type": scope.stateType]]
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return filter }
    var or: [[String: Any]] = [["title": ["containsIgnoreCase": q]]]
    let parts = q.split(separator: "-")
    if parts.count == 2, parts[0].allSatisfy(\.isLetter), let n = Int(parts[1]) {
        or.append(["team": ["key": ["eqIgnoreCase": String(parts[0])]], "number": ["eq": n]])
    }
    filter["or"] = or
    return filter
}

private struct RawTicketState: Decodable { var name: String?; var type: String?; var color: String? }
private struct RawTeam: Decodable { var key: String? }
private struct RawTicket: Decodable {
    var id: String?; var identifier: String?; var title: String?; var url: String?
    var priority: Double?; var updatedAt: String?; var branchName: String?
    var state: RawTicketState?; var team: RawTeam?
}
private struct RawPageInfo: Decodable { var hasNextPage: Bool?; var endCursor: String? }
private struct RawTicketConnection: Decodable { var nodes: [RawTicket]?; var pageInfo: RawPageInfo? }
private struct RawTicketViewer: Decodable { var assignedIssues: RawTicketConnection? }
private struct RawTicketData: Decodable { var viewer: RawTicketViewer? }
private struct RawGraphQLError: Decodable { var message: String? }

/// Test seam mirroring the paged `viewer.assignedIssues` envelope, errors included.
public struct RawTicketsForTest: Decodable {
    fileprivate var data: RawTicketData?
    fileprivate var errors: [RawGraphQLError]?
}

/// Map the paged envelope onto `LinearTicketPage`, or the first GraphQL error.
func parseLinearTickets(_ raw: RawTicketsForTest) -> Result<LinearTicketPage, LinearTicketsError> {
    if let first = raw.errors?.first {
        return .failure(.failed(first.message ?? "Linear returned an error."))
    }
    guard let conn = raw.data?.viewer?.assignedIssues else {
        return .failure(.failed("Linear's response had no assigned issues."))
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let tickets = (conn.nodes ?? []).compactMap { t -> LinearTicket? in
        guard let id = t.id, let identifier = t.identifier else { return nil }
        return LinearTicket(
            id: id, identifier: identifier, title: t.title ?? "", url: t.url ?? "",
            priority: Int(t.priority ?? 0),
            stateName: t.state?.name ?? "", stateType: t.state?.type ?? "",
            stateColor: t.state?.color ?? "", teamKey: t.team?.key ?? "",
            branchName: t.branchName ?? "", updatedAt: t.updatedAt.flatMap(iso.date(from:)))
    }
    let info = conn.pageInfo
    return .success(LinearTicketPage(tickets: tickets, hasNextPage: info?.hasNextPage ?? false,
                                     endCursor: info?.endCursor))
}

private let TICKETS_QUERY = """
query($first:Int!,$after:String,$filter:IssueFilter){ viewer{ assignedIssues(first:$first,after:$after,\
filter:$filter,orderBy:updatedAt){ nodes{ id identifier title url priority updatedAt branchName \
state{name type color} team{key} } pageInfo{ hasNextPage endCursor } } } }
"""

/// One page of the viewer's assigned issues, most recently updated first. Unlike the
/// picker's `getAssignedIssues`, failures come back as a reason the panel can show.
public func getAssignedTickets(scope: LinearTicketScope, search: String, first: Int, after: String?,
                               env: [String: String] = ProcessInfo.processInfo.environment)
    async -> Result<LinearTicketPage, LinearTicketsError> {
    guard let token = linearToken(env) else { return .failure(.noToken) }
    var req = URLRequest(url: LINEAR_GRAPHQL_URL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(token, forHTTPHeaderField: "Authorization")
    var variables: [String: Any] = ["first": first, "filter": linearTicketFilter(scope: scope, search: search)]
    if let after { variables["after"] = after }
    guard let body = try? JSONSerialization.data(withJSONObject: ["query": TICKETS_QUERY,
                                                                  "variables": variables]) else {
        return .failure(.failed("Couldn't encode the Linear query."))
    }
    req.httpBody = body
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // GraphQL errors arrive with a 400 too; decode before judging the status.
        if let raw = try? JSONDecoder().decode(RawTicketsForTest.self, from: data),
           raw.errors != nil || raw.data != nil {
            return parseLinearTickets(raw)
        }
        if status == 401 { return .failure(.failed("Linear rejected the API key.")) }
        return .failure(.failed("Linear answered HTTP \(status)."))
    } catch {
        return .failure(.failed(error.localizedDescription))
    }
}
