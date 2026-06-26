import Foundation
import JuancodeCore

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
