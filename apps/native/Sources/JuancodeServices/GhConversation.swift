import Foundation
import JuancodeCore

/// Full PR conversation fetch for the GitHub view: issue comments, review
/// verdicts, and inline review threads (with file/line and resolution state), in
/// one `gh api graphql` call. Same philosophy as the rest of `Gh.swift` — every
/// shell-out goes through `ProcessRunner` (environment inherited verbatim, the
/// prime directive) so `gh` uses the user's own auth; parsing is a pure function
/// over the JSON string so it unit-tests without spawning anything.

private let MAX_BUFFER = 16 * 1024 * 1024

/// Resolve the `gh` binary like the user's terminal would, honouring the
/// `JUANCODE_GH_BIN` override (same pattern as `Gh.swift`; re-declared here
/// because the original is file-private). Resolved per call so a test can point
/// it at a stub script via the env var.
private func ghBin() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}

// MARK: - wire types

/// One comment in a PR conversation — either an issue-level comment or one entry
/// of an inline review thread. `id` is the GraphQL node id (stable, dedupable);
/// `databaseId` is the REST id needed to *reply* to a review comment.
public struct PrConversationComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let databaseId: Int?
    public let author: String
    public let body: String
    public let createdAt: Date?
    public let url: String
    public init(id: String, databaseId: Int?, author: String, body: String,
                createdAt: Date?, url: String) {
        self.id = id; self.databaseId = databaseId; self.author = author
        self.body = body; self.createdAt = createdAt; self.url = url
    }
}

/// One inline review thread: the `path:line` it hangs off, whether it's been
/// resolved/outdated, and its comments in thread order.
public struct PrReviewThread: Sendable, Equatable, Identifiable {
    public let id: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let path: String
    public let line: Int?
    public let comments: [PrConversationComment]
    public init(id: String, isResolved: Bool, isOutdated: Bool, path: String,
                line: Int?, comments: [PrConversationComment]) {
        self.id = id; self.isResolved = isResolved; self.isOutdated = isOutdated
        self.path = path; self.line = line; self.comments = comments
    }

    /// The REST comment id a reply to this thread must target. GitHub's replies
    /// API (`…/pulls/<n>/comments/<id>/replies`) only accepts *top-level* review
    /// comments, so the target is always the thread's first comment — replying
    /// to a reply 422s. Nil when the first comment's `databaseId` is missing.
    public var replyTargetId: Int? { comments.first?.databaseId }
}

/// One PR review verdict (APPROVED / CHANGES_REQUESTED / COMMENTED / …), shown
/// as a chip in the conversation timeline.
public struct PrReviewItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let author: String
    public let state: String
    public let body: String
    public let createdAt: Date?
    public let url: String
    public init(id: String, author: String, state: String, body: String,
                createdAt: Date?, url: String) {
        self.id = id; self.author = author; self.state = state
        self.body = body; self.createdAt = createdAt; self.url = url
    }
}

/// A PR's full conversation: issue comments, review verdicts, and inline review
/// threads, plus the PR state (OPEN / CLOSED / MERGED) for the header.
public struct PrConversation: Sendable, Equatable {
    public let state: String
    public let issueComments: [PrConversationComment]
    public let reviews: [PrReviewItem]
    public let threads: [PrReviewThread]
    public init(state: String, issueComments: [PrConversationComment],
                reviews: [PrReviewItem], threads: [PrReviewThread]) {
        self.state = state; self.issueComments = issueComments
        self.reviews = reviews; self.threads = threads
    }
}

// MARK: - parsing (pure)

/// GraphQL response shape for the conversation query.
private struct ConversationResponse: Decodable {
    struct DataField: Decodable { let repository: Repository? }
    struct Repository: Decodable { let pullRequest: PullRequestNode? }
    struct PullRequestNode: Decodable {
        let state: String?
        let comments: CommentConnection?
        let reviews: ReviewConnection?
        let reviewThreads: ThreadConnection?
    }
    struct CommentConnection: Decodable { let nodes: [CommentNode]? }
    struct CommentNode: Decodable {
        let id: String?
        let databaseId: Int?
        let author: RawPrAuthor?
        let body: String?
        let createdAt: String?
        let url: String?
    }
    struct ReviewConnection: Decodable { let nodes: [ReviewNode]? }
    struct ReviewNode: Decodable {
        let id: String?
        let author: RawPrAuthor?
        let state: String?
        let body: String?
        let createdAt: String?
        let url: String?
    }
    struct ThreadConnection: Decodable { let nodes: [ThreadNode]? }
    struct ThreadNode: Decodable {
        let id: String?
        let isResolved: Bool?
        let isOutdated: Bool?
        let path: String?
        let line: Int?
        let comments: CommentConnection?
    }
    let data: DataField?
}

/// Parse an ISO-8601 timestamp (with or without fractional seconds) into a
/// `Date`, or nil when absent/unparseable — a garbage `createdAt` must not sink
/// the whole conversation.
private func parseIsoDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

/// Map the GraphQL response onto our wire shape. Pure; exposed for testing.
/// Field-tolerant (missing `databaseId`/`line`/date → nil, missing author → ""
/// like `parsePrActivity`; a comment/review/thread without an `id` is dropped —
/// it can't be identified reliably). Returns nil only when the JSON is
/// structurally malformed: no `repository.pullRequest` object at all.
func parsePrConversation(_ json: String) -> PrConversation? {
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(ConversationResponse.self, from: data),
          let pr = decoded.data?.repository?.pullRequest else { return nil }

    func mapComments(_ conn: ConversationResponse.CommentConnection?) -> [PrConversationComment] {
        (conn?.nodes ?? []).compactMap { c in
            guard let id = c.id else { return nil }
            return PrConversationComment(
                id: id, databaseId: c.databaseId, author: c.author?.login ?? "",
                body: c.body ?? "", createdAt: parseIsoDate(c.createdAt), url: c.url ?? "")
        }
    }

    let reviews: [PrReviewItem] = (pr.reviews?.nodes ?? []).compactMap { r in
        guard let id = r.id else { return nil }
        return PrReviewItem(
            id: id, author: r.author?.login ?? "", state: (r.state ?? "").uppercased(),
            body: r.body ?? "", createdAt: parseIsoDate(r.createdAt), url: r.url ?? "")
    }

    let threads: [PrReviewThread] = (pr.reviewThreads?.nodes ?? []).compactMap { t in
        guard let id = t.id else { return nil }
        return PrReviewThread(
            id: id, isResolved: t.isResolved ?? false, isOutdated: t.isOutdated ?? false,
            path: t.path ?? "", line: t.line, comments: mapComments(t.comments))
    }

    return PrConversation(
        state: (pr.state ?? "").uppercased(),
        issueComments: mapComments(pr.comments),
        reviews: reviews,
        threads: threads)
}

// MARK: - fetch

/// Read a PR's full conversation via one `gh api graphql` call, scoped by the
/// owner/name lifted from the PR's url (no extra `gh repo view` round-trip).
/// Returns nil when gh is missing/unauthenticated, the url isn't a github.com PR
/// url, or the response won't parse — the view treats nil as "couldn't load".
public func getPrConversation(_ cwd: String, number: Int, prUrl: String) async -> PrConversation? {
    guard let slug = repoSlug(fromPrUrl: prUrl) else { return nil }
    let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          state
          comments(last: 50) { nodes { id databaseId author { login } body createdAt url } }
          reviews(last: 30) { nodes { id author { login } state body createdAt url } }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line
              comments(first: 50) { nodes { id databaseId author { login } body createdAt url } }
            }
          }
        }
      }
    }
    """
    do {
        let r = try await ProcessRunner.capture(
            ghBin(),
            ["api", "graphql", "-f", "query=\(query)",
             "-f", "owner=\(slug.owner)", "-f", "name=\(slug.name)",
             "-F", "number=\(number)"],
            cwd: cwd, maxBytes: MAX_BUFFER)
        guard r.ok else { return nil }
        return parsePrConversation(r.stdout)
    } catch {
        return nil
    }
}
