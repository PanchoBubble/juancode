import Foundation

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

    private func get<T: Decodable>(_ path: String, _ query: [(String, String)]) async -> T? {
        guard var comps = URLComponents(string: baseURL.hasSuffix("/")
                                        ? String(baseURL.dropLast()) : baseURL) else { return nil }
        comps.path = path
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // A non-2xx carries the core's own sentence about what went wrong, which
            // belongs in a log rather than in a decode that would fail confusingly.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("juancode: \(path) answered \(http.statusCode): "
                      + String(decoding: data.prefix(300), as: UTF8.self))
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            NSLog("juancode: \(path) did not answer: \(error.localizedDescription)")
            return nil
        }
    }
}
