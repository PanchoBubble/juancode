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

/// One emoji reaction bucket on a comment/review — GitHub's `reactionGroups`
/// entry: the content enum (`THUMBS_UP`, `HEART`, …) and how many people reacted
/// with it. Only non-empty buckets are kept.
public struct PrReaction: Sendable, Equatable, Identifiable {
    public let content: String
    public let count: Int
    public var id: String { content }
    public init(content: String, count: Int) {
        self.content = content; self.count = count
    }

    /// The emoji for GitHub's reaction content enum; empty for an unknown value.
    public var emoji: String {
        switch content {
        case "THUMBS_UP": return "👍"
        case "THUMBS_DOWN": return "👎"
        case "LAUGH": return "😄"
        case "HOORAY": return "🎉"
        case "CONFUSED": return "😕"
        case "HEART": return "❤️"
        case "ROCKET": return "🚀"
        case "EYES": return "👀"
        default: return ""
        }
    }
}

/// One comment in a PR conversation — either an issue-level comment or one entry
/// of an inline review thread. `id` is the GraphQL node id (stable, dedupable);
/// `databaseId` is the REST id needed to *reply* to a review comment.
public struct PrConversationComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let databaseId: Int?
    public let author: String
    /// The author's GitHub avatar URL, for the thumbnail next to their handle;
    /// nil when the API didn't report one (ghost/deleted account).
    public let authorAvatarUrl: String?
    public let body: String
    public let createdAt: Date?
    public let url: String
    /// For an inline review comment: the file it hangs off, and the line within
    /// it. Both nil for an issue-level comment (which has no location).
    public let path: String?
    public let line: Int?
    /// Emoji reactions on this comment, non-empty buckets only.
    public let reactions: [PrReaction]
    public init(id: String, databaseId: Int?, author: String, body: String,
                createdAt: Date?, url: String, authorAvatarUrl: String? = nil,
                path: String? = nil, line: Int? = nil, reactions: [PrReaction] = []) {
        self.id = id; self.databaseId = databaseId; self.author = author
        self.authorAvatarUrl = authorAvatarUrl
        self.body = body; self.createdAt = createdAt; self.url = url
        self.path = path; self.line = line; self.reactions = reactions
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
    /// The reviewer's GitHub avatar URL, for the thumbnail next to their handle.
    public let authorAvatarUrl: String?
    public let state: String
    public let body: String
    public let createdAt: Date?
    public let url: String
    /// The inline file comments submitted as part of this review, in thread
    /// order — rendered nested under the review event, the way GitHub's
    /// Conversation tab groups a review with its comments. Empty for a bare
    /// verdict (approve/comment with no inline notes).
    public let comments: [PrConversationComment]
    /// Emoji reactions on the review summary, non-empty buckets only.
    public let reactions: [PrReaction]
    public init(id: String, author: String, state: String, body: String,
                createdAt: Date?, url: String, authorAvatarUrl: String? = nil,
                comments: [PrConversationComment] = [], reactions: [PrReaction] = []) {
        self.id = id; self.author = author; self.authorAvatarUrl = authorAvatarUrl
        self.state = state
        self.body = body; self.createdAt = createdAt; self.url = url
        self.comments = comments; self.reactions = reactions
    }
}

/// One commit on the PR, for the interleaved conversation timeline: the short
/// SHA, the first line of the message, the author handle/name, and when it
/// landed.
public struct PrCommit: Sendable, Equatable, Identifiable {
    /// The abbreviated (7-char) SHA — also the identity for the timeline.
    public let abbreviatedOid: String
    public let oid: String
    public let messageHeadline: String
    public let author: String
    public let committedDate: Date?
    public var id: String { oid }
    public init(oid: String, abbreviatedOid: String, messageHeadline: String,
                author: String, committedDate: Date?) {
        self.oid = oid; self.abbreviatedOid = abbreviatedOid
        self.messageHeadline = messageHeadline; self.author = author
        self.committedDate = committedDate
    }
}

/// A PR's full conversation: issue comments, review verdicts, and inline review
/// threads, plus the PR state (OPEN / CLOSED / MERGED) for the header.
public struct PrConversation: Sendable, Equatable {
    public let state: String
    /// The PR's own description (the opening body), as raw markdown; empty when
    /// the PR has no description.
    public let body: String
    public let issueComments: [PrConversationComment]
    public let reviews: [PrReviewItem]
    public let threads: [PrReviewThread]
    public let commits: [PrCommit]
    public init(state: String, issueComments: [PrConversationComment],
                reviews: [PrReviewItem], threads: [PrReviewThread], body: String = "",
                commits: [PrCommit] = []) {
        self.state = state; self.body = body; self.issueComments = issueComments
        self.reviews = reviews; self.threads = threads; self.commits = commits
    }

    /// Resolution state for a review comment, keyed by its GraphQL node id, lifted
    /// from the review threads (comments don't carry it themselves). Lets the
    /// review-grouped rendering show a "resolved"/"outdated" badge and find the
    /// reply target without re-fetching threads.
    public struct CommentThreadInfo: Sendable, Equatable {
        public let isResolved: Bool
        public let isOutdated: Bool
        public let replyTargetId: Int?
    }

    public func threadInfo(forCommentId id: String) -> CommentThreadInfo? {
        for t in threads where t.comments.contains(where: { $0.id == id }) {
            return CommentThreadInfo(isResolved: t.isResolved, isOutdated: t.isOutdated,
                                     replyTargetId: t.replyTargetId)
        }
        return nil
    }
}

// MARK: - parsing (pure)

/// GraphQL response shape for the conversation query.
private struct ConversationResponse: Decodable {
    struct DataField: Decodable { let repository: Repository? }
    struct Repository: Decodable { let pullRequest: PullRequestNode? }
    struct PullRequestNode: Decodable {
        let state: String?
        let body: String?
        let comments: CommentConnection?
        let reviews: ReviewConnection?
        let reviewThreads: ThreadConnection?
        let commits: CommitConnection?
    }
    struct CommentConnection: Decodable { let nodes: [CommentNode]? }
    struct CommentNode: Decodable {
        let id: String?
        let databaseId: Int?
        let author: RawPrAuthor?
        let body: String?
        let createdAt: String?
        let url: String?
        let path: String?
        let line: Int?
        let reactionGroups: [ReactionGroupNode]?
    }
    struct ReactionGroupNode: Decodable {
        let content: String?
        let reactors: ReactorConnection?
    }
    struct ReactorConnection: Decodable { let totalCount: Int? }
    struct ReviewConnection: Decodable { let nodes: [ReviewNode]? }
    struct ReviewNode: Decodable {
        let id: String?
        let author: RawPrAuthor?
        let state: String?
        let body: String?
        let createdAt: String?
        let url: String?
        let comments: CommentConnection?
        let reactionGroups: [ReactionGroupNode]?
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
    struct CommitConnection: Decodable { let nodes: [CommitEdge]? }
    struct CommitEdge: Decodable { let commit: CommitNode? }
    struct CommitNode: Decodable {
        let oid: String?
        let abbreviatedOid: String?
        let messageHeadline: String?
        let committedDate: String?
        let authors: AuthorConnection?
    }
    struct AuthorConnection: Decodable { let nodes: [CommitAuthor]? }
    struct CommitAuthor: Decodable {
        let name: String?
        let user: RawPrAuthor?
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

    func mapReactions(_ groups: [ConversationResponse.ReactionGroupNode]?) -> [PrReaction] {
        (groups ?? []).compactMap { g in
            guard let content = g.content, let count = g.reactors?.totalCount, count > 0 else { return nil }
            return PrReaction(content: content, count: count)
        }
    }

    func mapComments(_ conn: ConversationResponse.CommentConnection?) -> [PrConversationComment] {
        (conn?.nodes ?? []).compactMap { c in
            guard let id = c.id else { return nil }
            return PrConversationComment(
                id: id, databaseId: c.databaseId, author: c.author?.login ?? "",
                body: c.body ?? "", createdAt: parseIsoDate(c.createdAt), url: c.url ?? "",
                authorAvatarUrl: c.author?.avatarUrl, path: c.path, line: c.line,
                reactions: mapReactions(c.reactionGroups))
        }
    }

    let reviews: [PrReviewItem] = (pr.reviews?.nodes ?? []).compactMap { r in
        guard let id = r.id else { return nil }
        return PrReviewItem(
            id: id, author: r.author?.login ?? "", state: (r.state ?? "").uppercased(),
            body: r.body ?? "", createdAt: parseIsoDate(r.createdAt), url: r.url ?? "",
            authorAvatarUrl: r.author?.avatarUrl, comments: mapComments(r.comments),
            reactions: mapReactions(r.reactionGroups))
    }

    let threads: [PrReviewThread] = (pr.reviewThreads?.nodes ?? []).compactMap { t in
        guard let id = t.id else { return nil }
        return PrReviewThread(
            id: id, isResolved: t.isResolved ?? false, isOutdated: t.isOutdated ?? false,
            path: t.path ?? "", line: t.line, comments: mapComments(t.comments))
    }

    // Drop empty-review noise: GitHub records a bare COMMENTED review for every
    // inline-comment reply, which — with no body and no own inline comments —
    // would render as a contentless "commented" card. Only that exact shape is
    // dropped; verdicts and anything with a body or comments are kept.
    let meaningfulReviews = reviews.filter {
        !($0.state == "COMMENTED" && $0.body.isEmpty && $0.comments.isEmpty && $0.reactions.isEmpty)
    }

    let commits: [PrCommit] = (pr.commits?.nodes ?? []).compactMap { edge in
        guard let c = edge.commit, let oid = c.oid else { return nil }
        let author = c.authors?.nodes?.first
        return PrCommit(
            oid: oid,
            abbreviatedOid: c.abbreviatedOid ?? String(oid.prefix(7)),
            messageHeadline: c.messageHeadline ?? "",
            author: author?.user?.login ?? author?.name ?? "",
            committedDate: parseIsoDate(c.committedDate))
    }

    return PrConversation(
        state: (pr.state ?? "").uppercased(),
        issueComments: mapComments(pr.comments),
        reviews: meaningfulReviews,
        threads: threads,
        body: pr.body ?? "",
        commits: commits)
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
          body
          comments(last: 50) { nodes { id databaseId author { login avatarUrl } body createdAt url reactionGroups { content reactors { totalCount } } } }
          reviews(last: 30) {
            nodes {
              id author { login avatarUrl } state body createdAt url reactionGroups { content reactors { totalCount } }
              comments(first: 50) { nodes { id databaseId author { login avatarUrl } body createdAt url path line reactionGroups { content reactors { totalCount } } } }
            }
          }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line
              comments(first: 50) { nodes { id databaseId author { login avatarUrl } body createdAt url path line reactionGroups { content reactors { totalCount } } } }
            }
          }
          commits(last: 100) {
            nodes { commit { oid abbreviatedOid messageHeadline committedDate authors(first: 1) { nodes { name user { login avatarUrl } } } } }
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
