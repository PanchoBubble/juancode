import Foundation
import JuancodeCore

/// The GitHub surface as the app reads it off the core, rather than as the app used to
/// compute it for itself.
///
/// Everything here is a decode of what `juancoded` serves — the parsed failing-CI log
/// and a session's review pass — plus the two writes that stage and unstage a diff
/// comment. Nothing in this file parses a log, runs a model or shells out to anything:
/// that moved into the daemon (juancode-52e8.14.6) for the reason the whole epic
/// exists, which is that a Mac that has been walked away from is exactly when somebody
/// wants to read why CI went red, and a phone cannot shell out to `gh`.
///
/// The field names are the core's, because the same JSON reaches the phone console.

// MARK: - the parsed Actions log

/// A run of log text sharing one set of ANSI attributes.
public struct ActionsLogSpan: Codable, Sendable, Equatable {
    public let text: String
    /// The raw SGR foreground code (30–37 / 90–97), or nil for the default colour.
    /// Raw rather than resolved: which red to draw depends on the theme, and that is
    /// the view's business, not the core's.
    public let fg: Int?
    public let bold: Bool

    public init(text: String, fg: Int? = nil, bold: Bool = false) {
        self.text = text; self.fg = fg; self.bold = bold
    }

    private enum CodingKeys: String, CodingKey { case text, fg, bold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fg = try c.decodeIfPresent(Int.self, forKey: .fg)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
    }
}

/// What an Actions log command said about a line, when it said anything.
public enum ActionsLogSeverity: String, Codable, Sendable, Equatable {
    case plain, command, debug, notice, warning, error
}

/// One log line, with the marker and the timestamp already stripped.
public struct ActionsLogLine: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let severity: ActionsLogSeverity
    /// Milliseconds since the epoch, or nil when the line had no stamp.
    public let timestamp: Int?
    public let spans: [ActionsLogSpan]

    /// The line as plain text — for search, copy and the collapsed summary.
    public var text: String { spans.map(\.text).joined() }
    public var date: Date? { timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    public init(id: Int, severity: ActionsLogSeverity, timestamp: Int?, spans: [ActionsLogSpan]) {
        self.id = id; self.severity = severity; self.timestamp = timestamp; self.spans = spans
    }
}

/// A `##[group]` … `##[endgroup]` fold, or the implicit group holding the lines that
/// sat outside any fold (empty title, not foldable).
public struct ActionsLogGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let foldable: Bool
    public let lines: [ActionsLogLine]
    /// Decided by the core rather than recomputed here, so the desktop and the phone
    /// open the same folds.
    public let hasError: Bool
}

/// All the log for one job step, in the order gh emitted it.
public struct ActionsLogSection: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let runId: String?
    public let job: String
    public let step: String
    public let groups: [ActionsLogGroup]
    public let hasError: Bool
    /// Every error line in the step — the "why is CI red" answer, with no fold to open
    /// first.
    public let errorLines: [ActionsLogLine]
}

/// A parsed failing-CI log.
public struct ActionsLog: Codable, Sendable, Equatable {
    public let sections: [ActionsLogSection]
    /// True when the head of the log was dropped to fit the core's cap.
    public let truncated: Bool

    public init(sections: [ActionsLogSection] = [], truncated: Bool = false) {
        self.sections = sections; self.truncated = truncated
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var errorLines: [ActionsLogLine] { sections.flatMap(\.errorLines) }
}

// MARK: - a review pass

public enum ReviewSeverityLevel: String, Codable, Sendable {
    case critical, high, medium, low, info
}

/// One finding, anchored to the file and line it concerns.
public struct ReviewFindingItem: Codable, Sendable, Equatable {
    public let file: String
    /// `old` or `new` — which side of the hunk the line is on.
    public let side: String
    /// Nil for a file-level finding with no single line, which the core's schema asks
    /// the model for explicitly rather than letting it pick line 1.
    public let line: Int?
    public let severity: ReviewSeverityLevel
    public let title: String
    public let note: String

    public init(file: String, side: String, line: Int?, severity: ReviewSeverityLevel,
                title: String, note: String) {
        self.file = file; self.side = side; self.line = line
        self.severity = severity; self.title = title; self.note = note
    }
}

/// One review pass, as the core cached it.
public struct ReviewPass: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, empty, error }
    public let status: Status
    public let findings: [ReviewFindingItem]
    public let summary: String?
    public let createdAt: Int
    /// Present when the pass could not run or its output could not be read. Cached
    /// like any other result: "the last pass failed, and this is why" is what the
    /// panel shows, and losing it would make a failure look like a review nobody ran.
    public let error: String?

    public init(status: Status, findings: [ReviewFindingItem] = [], summary: String? = nil,
                createdAt: Int = 0, error: String? = nil) {
        self.status = status; self.findings = findings; self.summary = summary
        self.createdAt = createdAt; self.error = error
    }
}

/// One inline comment staged against a session's diff.
public struct StagedDiffComment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let file: String
    public let side: String
    public let line: Int
    public let endLine: Int
    public let body: String
    public let createdAt: Int
    public let quote: String?
    public let commitSha: String?
    public let commitSubject: String?
}

// MARK: - the reads, over HTTP

/// The core's GitHub read surface, over plain HTTP.
///
/// HTTP and not the socket because every one of these is a question somebody asks once
/// and leaves — open a PR, look at why it is red, close it again. A subscription would
/// be a socket held open for a single answer, and the sidecar and the phone console
/// already reach the core this way.
public struct GitHubReads: Sendable {
    /// The core's HTTP root, e.g. `http://127.0.0.1:4280`.
    public let baseURL: String
    /// How long one read may take. Generous, because the far side is shelling out to
    /// `gh` and then waiting on GitHub — but bounded, because a panel that never
    /// answers is worse than one that says it could not.
    public var timeout: TimeInterval = 45

    public init(baseURL: String, timeout: TimeInterval = 45) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// The failing-step logs behind a PR's red checks, already parsed into folds and
    /// lines. An empty log is an answer — a green PR has no failing build — so nil
    /// means the read itself failed.
    public func actionsLog(cwd: String, number: Int) async -> ActionsLog? {
        await get("/api/pr/actions-log", [("cwd", cwd), ("number", String(number))])
    }

    /// A PR's conversation, already merged into the chronology it is read in, with each
    /// review carrying the threads it started. The owner/name is lifted from `prUrl` on
    /// the far side, which is what saves a `gh repo view` per read.
    public func timeline(cwd: String, number: Int, prUrl: String) async -> PrTimeline? {
        await get("/api/pr/timeline",
                  [("cwd", cwd), ("number", String(number)), ("url", prUrl)])
    }

    /// A PR's CI checks, each with the outcome its row draws already decided.
    public func checks(cwd: String, number: Int) async -> [PrCheckRow]? {
        let body: ChecksBody? = await get("/api/pr/checks",
                                          [("cwd", cwd), ("number", String(number))])
        return body?.checks
    }

    private struct ChecksBody: Decodable { let checks: [PrCheckRow] }

    // MARK: - the folder's list, and the two reads that reach past its page

    /// One folder's open PRs, with the triage answer and the order already applied.
    ///
    /// `tracked` leads the list; `sort: "submitted"` asks for strict newest-first
    /// instead. `teams` are the viewer's team slugs, which the caller knows and `gh`
    /// does not report cheaply, so a team review request counts as an ask.
    public func prs(cwd: String, tracked: [Int] = [], sort: String? = nil,
                    teams: [String] = []) async -> PrsBody? {
        var query = [("cwd", cwd)]
        if !tracked.isEmpty { query.append(("tracked", tracked.map(String.init).joined(separator: ","))) }
        if let sort { query.append(("sort", sort)) }
        if !teams.isEmpty { query.append(("teams", teams.joined(separator: ","))) }
        return await get("/api/prs", query)
    }

    /// A repo-scoped PR search. The list answers a page of the newest PRs; this is how
    /// the ones beyond it are reached, and the caller unions the two.
    public func searchPrs(cwd: String, query: String) async -> [PullRequest]? {
        let body: SearchBody? = await get("/api/prs/search", [("cwd", cwd), ("q", query)])
        return body?.prs
    }

    private struct SearchBody: Decodable { let prs: [PullRequest] }

    /// The open PR for one branch, or nil. Nil is ambiguous on purpose here: "no PR"
    /// and "could not ask" both mean the header has nothing to link to, and the caller
    /// caches either answer for the same interval.
    public func prForBranch(cwd: String, branch: String) async -> PullRequest? {
        let body: BranchPrBody? = await get("/api/pr/for-branch",
                                            [("cwd", cwd), ("branch", branch)])
        return body?.pr
    }

    private struct BranchPrBody: Decodable { let pr: PullRequest? }

    /// A checkout's repo identity (`owner/name`), or nil when it has no GitHub remote.
    public func repoNwo(cwd: String) async -> String? {
        let body: RepoBody? = await get("/api/repo", [("cwd", cwd)])
        return body?.nwo
    }

    private struct RepoBody: Decodable { let nwo: String? }

    /// The viewer's own queue: every open PR they authored plus every one that asked
    /// for their review, across repos this machine may have no clone of.
    public func viewerPrs(cwd: String? = nil, teams: [String] = []) async -> ViewerPrResult? {
        var query: [(String, String)] = []
        if let cwd, !cwd.isEmpty { query.append(("cwd", cwd)) }
        if !teams.isEmpty { query.append(("teams", teams.joined(separator: ","))) }
        return await get("/api/prs/viewer", query)
    }

    /// An open PR's net diff, in the same per-file shape the working tree answers
    /// with. Throws rather than answering nil: the panel draws the reason.
    public func prDiff(cwd: String, number: Int) async throws -> DiffResult {
        try await ask("/api/pr/diff", [("cwd", cwd), ("number", String(number))],
                      "Could not read the diff for PR #\(number)")
    }

    // MARK: - the writes

    /// Open a PR for the checkout's current branch. The caller pushes the branch
    /// first — this core will not push as a side effect of a different verb.
    public func createPr(cwd: String, title: String, body: String,
                         draft: Bool) async throws -> PrCreateResult {
        try await tell("/api/pr/create",
                       ["cwd": cwd, "title": title, "body": body, "draft": draft],
                       "Could not open the pull request")
    }

    /// Comment on a PR. `replyTo` is the REST id of the review comment being replied
    /// to; absent posts a top-level comment. One call and not two, because the
    /// composer is one box whose target is whether a thread is open under it.
    public func comment(cwd: String, number: Int, body: String, replyTo: Int? = nil) async throws {
        var payload: [String: Any] = ["cwd": cwd, "number": number, "body": body]
        if let replyTo { payload["replyTo"] = replyTo }
        let _: OkBody = try await tell("/api/pr/comment", payload,
                                       "Could not post the comment")
    }

    /// Re-run a PR's CI, or only its failed jobs.
    public func rerunChecks(cwd: String, number: Int, failedOnly: Bool) async throws {
        let _: OkBody = try await tell("/api/pr/rerun",
                                       ["cwd": cwd, "number": number, "failedOnly": failedOnly],
                                       "Could not re-run the checks")
    }

    private struct OkBody: Decodable { let ok: Bool }

    /// A read whose failure the caller shows rather than swallows. The thrown message
    /// is the core's own sentence when it sent one — which is `gh`'s words for what
    /// went wrong — and `fallback` only when the request never got that far.
    private func ask<T: Decodable>(_ path: String, _ query: [(String, String)],
                                   _ fallback: String) async throws -> T {
        guard let url = urlFor(path, query) else { throw GitHubError(fallback) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return try await send(request, path).get(or: fallback)
    }

    /// One POST of a JSON body. Separate from a read only in the verb and the body:
    /// the failure handling, the timeout and the logging are one path, so a write
    /// cannot start reporting failures differently from a read.
    private func tell<T: Decodable>(_ path: String, _ payload: [String: Any],
                                    _ fallback: String) async throws -> T {
        guard let url = urlFor(path, []),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw GitHubError(fallback)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request, path).get(or: fallback)
    }

    private func get<T: Decodable>(_ path: String, _ query: [(String, String)]) async -> T? {
        guard let url = urlFor(path, query) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return try? await send(request, path).get()
    }

    private func urlFor(_ path: String, _ query: [(String, String)]) -> URL? {
        guard var comps = URLComponents(string: baseURL.hasSuffix("/")
                                        ? String(baseURL.dropLast()) : baseURL) else { return nil }
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.url
    }

    /// The one request path. `Result` and not `T?` because half these calls draw the
    /// reason and the other half only need to know there is none, and a second copy of
    /// this would eventually report the two differently.
    private func send<T: Decodable>(_ request: URLRequest,
                                    _ path: String) async -> Result<T, GitHubError> {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // A non-2xx carries the core's own sentence about what went wrong, which
            // belongs in the thrown message as well as in the log.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(decoding: data.prefix(600), as: UTF8.self)
                NSLog("juancode: \(path) answered \(http.statusCode): \(body)")
                return .failure(GitHubError(errorSentence(in: data)
                                            ?? "the core answered \(http.statusCode)"))
            }
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            NSLog("juancode: \(path) did not answer: \(error.localizedDescription)")
            return .failure(GitHubError(error.localizedDescription))
        }
    }

    /// The `{"error": "..."}` a refused request carries, which is `gh`'s own words for
    /// what went wrong and the only ones worth showing somebody.
    private func errorSentence(in data: Data) -> String? {
        struct ErrorBody: Decodable { let error: String? }
        let sentence = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        return sentence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }?
            .isEmpty == false ? sentence : nil
    }
}

private extension Result where Failure == GitHubError {
    /// The value, or the failure's own sentence — falling back to the caller's only
    /// when the request never produced one.
    func get(or fallback: String) throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error):
            throw error.message.isEmpty ? GitHubError(fallback) : error
        }
    }
}

/// A GitHub read or write that failed, carrying the sentence a panel shows.
///
/// The app-side twin of the daemon's `GhError`: the reason arrives as JSON on a 502
/// rather than on a `gh` process's stderr, because the process is in the daemon now.
public struct GitHubError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One folder's open PRs, with the triage answer and the order already applied — the
/// body of `GET /api/prs`.
public struct PrsBody: Codable, Sendable, Equatable {
    public var available: Bool
    public var prs: [PullRequest]
    public var viewer: String?
    public var error: String?
    /// The PRs that need the viewer, most urgent first, each with its reason.
    public var needsYou: [NeedsYouRow]

    public init(available: Bool, prs: [PullRequest] = [], viewer: String? = nil,
                error: String? = nil, needsYou: [NeedsYouRow] = []) {
        self.available = available; self.prs = prs; self.viewer = viewer
        self.error = error; self.needsYou = needsYou
    }

    private enum CodingKeys: String, CodingKey { case available, prs, viewer, error, needsYou }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        prs = try c.decodeIfPresent([PullRequest].self, forKey: .prs) ?? []
        viewer = try c.decodeIfPresent(String.self, forKey: .viewer)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        needsYou = try c.decodeIfPresent([NeedsYouRow].self, forKey: .needsYou) ?? []
    }

    /// The list as the rest of the app already reads one.
    public var listResult: PrListResult {
        PrListResult(available: available, prs: prs, viewer: viewer, error: error)
    }
}
