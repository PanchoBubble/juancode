import Foundation

/// A PR's conversation as the core hands it over, rather than as the app used to
/// assemble it for itself.
///
/// Everything here is a decode of what `juancoded` serves at `/api/pr/timeline` and
/// `/api/pr/checks`. The merge into one chronology, the folding of a review's replies
/// into the threads they belong to, the dropping of a review event that would draw as
/// an empty card, and the collapse of a check's bucket/state pair into an outcome all
/// happen in the daemon (juancode-52e8.14.6, `juancoded_core::pr_timeline`). Nothing in
/// this file decides any of it: two clients that each implemented the tie-breaks would
/// eventually draw two different chronologies of one conversation, and the phone —
/// which cannot shell out to `gh` — has to see the same one the desktop does.
///
/// Timestamps are milliseconds since the epoch, like every other timestamp on this
/// wire, with a `Date` beside them for the views that want one. The field names are the
/// core's, because the same JSON reaches the phone console.

// MARK: - the pieces of a conversation

/// One emoji reaction bucket — GitHub's `reactionGroups` entry. Only buckets somebody
/// actually reacted in are served.
public struct PrReaction: Codable, Sendable, Equatable, Identifiable {
    /// GitHub's content enum: `THUMBS_UP`, `HEART`, `ROCKET`, …
    public let content: String
    public let count: Int
    public var id: String { content }

    public init(content: String, count: Int) {
        self.content = content; self.count = count
    }

    /// The emoji for GitHub's reaction enum; empty for a value this build does not
    /// know, which the reaction bar then leaves out rather than drawing blank.
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

/// One comment in a conversation: an issue-level comment, or one turn of an inline
/// review thread.
public struct PrConversationComment: Codable, Sendable, Equatable, Identifiable {
    /// The GraphQL node id — stable, and what identity is keyed on.
    public let id: String
    /// The REST id a *reply* has to target. Absent when GitHub did not report one,
    /// which is why a thread with no reply target offers no Reply button.
    public let databaseId: Int?
    public let author: String
    public let authorAvatarUrl: String?
    public let body: String
    /// Milliseconds since the epoch, or nil when the stamp was missing or garbage.
    public let createdAt: Int?
    public let url: String
    /// For an inline comment: the file it hangs off and the line within it. Both nil
    /// for an issue-level comment, which has no location.
    public let path: String?
    public let line: Int?
    /// The unified-diff hunk the comment is anchored to — an `@@ … @@` header plus the
    /// context ending at the commented line.
    public let diffHunk: String?
    public let reactions: [PrReaction]

    public var created: Date? { millis(createdAt) }

    public init(id: String, databaseId: Int? = nil, author: String = "",
                authorAvatarUrl: String? = nil, body: String = "", createdAt: Int? = nil,
                url: String = "", path: String? = nil, line: Int? = nil,
                diffHunk: String? = nil, reactions: [PrReaction] = []) {
        self.id = id; self.databaseId = databaseId; self.author = author
        self.authorAvatarUrl = authorAvatarUrl; self.body = body
        self.createdAt = createdAt; self.url = url; self.path = path; self.line = line
        self.diffHunk = diffHunk; self.reactions = reactions
    }

    private enum CodingKeys: String, CodingKey {
        case id, databaseId, author, authorAvatarUrl, body, createdAt, url, path, line
        case diffHunk, reactions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        databaseId = try c.decodeIfPresent(Int.self, forKey: .databaseId)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        diffHunk = try c.decodeIfPresent(String.self, forKey: .diffHunk)
        reactions = try c.decodeIfPresent([PrReaction].self, forKey: .reactions) ?? []
    }
}

/// One inline review thread: where it hangs, whether it has been dealt with, and its
/// comments in thread order.
public struct PrReviewThread: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let path: String
    public let line: Int?
    public let comments: [PrConversationComment]

    public init(id: String, isResolved: Bool = false, isOutdated: Bool = false,
                path: String = "", line: Int? = nil,
                comments: [PrConversationComment] = []) {
        self.id = id; self.isResolved = isResolved; self.isOutdated = isOutdated
        self.path = path; self.line = line; self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id, isResolved, isOutdated, path, line, comments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        isOutdated = try c.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        comments = try c.decodeIfPresent([PrConversationComment].self, forKey: .comments) ?? []
    }
}

/// One review verdict, with the inline comments it submitted.
public struct PrReviewItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let author: String
    public let authorAvatarUrl: String?
    /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING, upper-cased.
    public let state: String
    public let body: String
    public let createdAt: Int?
    public let url: String
    /// The inline comments submitted as part of this review, in thread order.
    public let comments: [PrConversationComment]
    public let reactions: [PrReaction]

    public var created: Date? { millis(createdAt) }

    public init(id: String, author: String = "", authorAvatarUrl: String? = nil,
                state: String = "", body: String = "", createdAt: Int? = nil,
                url: String = "", comments: [PrConversationComment] = [],
                reactions: [PrReaction] = []) {
        self.id = id; self.author = author; self.authorAvatarUrl = authorAvatarUrl
        self.state = state; self.body = body; self.createdAt = createdAt; self.url = url
        self.comments = comments; self.reactions = reactions
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, authorAvatarUrl, state, body, createdAt, url, comments, reactions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        comments = try c.decodeIfPresent([PrConversationComment].self, forKey: .comments) ?? []
        reactions = try c.decodeIfPresent([PrReaction].self, forKey: .reactions) ?? []
    }
}

/// One commit on the PR, interleaved into the timeline.
public struct PrCommit: Codable, Sendable, Equatable, Identifiable {
    public let oid: String
    /// The abbreviated (7-char) SHA the row draws.
    public let abbreviatedOid: String
    public let messageHeadline: String
    /// The author's login when GitHub knows the account, otherwise the name on the
    /// commit — an unlinked commit still has an author worth showing.
    public let author: String
    public let committedDate: Int?
    public var id: String { oid }

    public var committed: Date? { millis(committedDate) }

    public init(oid: String, abbreviatedOid: String = "", messageHeadline: String = "",
                author: String = "", committedDate: Int? = nil) {
        self.oid = oid; self.abbreviatedOid = abbreviatedOid
        self.messageHeadline = messageHeadline; self.author = author
        self.committedDate = committedDate
    }

    private enum CodingKeys: String, CodingKey {
        case oid, abbreviatedOid, messageHeadline, author, committedDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        oid = try c.decodeIfPresent(String.self, forKey: .oid) ?? ""
        abbreviatedOid = try c.decodeIfPresent(String.self, forKey: .abbreviatedOid)
            ?? String(oid.prefix(7))
        messageHeadline = try c.decodeIfPresent(String.self, forKey: .messageHeadline) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        committedDate = try c.decodeIfPresent(Int.self, forKey: .committedDate)
    }
}

/// One inline thread as the conversation draws it: the anchor, whether it has been
/// dealt with, the id a reply must target, and every comment in it — root first.
///
/// Which review a thread belongs to is the core's answer, not a lookup done here: a
/// comment that only replies to a thread an earlier review opened belongs under that
/// thread's root rather than in a card of its own.
public struct PrThreadGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String?
    public let line: Int?
    public let isResolved: Bool
    public let isOutdated: Bool
    public let replyTargetId: Int?
    /// Never empty: a group with no comments is not a thread anybody opened.
    public let comments: [PrConversationComment]

    /// The comment the thread hangs off — the one carrying the diff hunk.
    public var root: PrConversationComment? { comments.first }
    /// Everything after the root: the back-and-forth.
    public var replies: [PrConversationComment] { Array(comments.dropFirst()) }

    public init(id: String, path: String? = nil, line: Int? = nil, isResolved: Bool = false,
                isOutdated: Bool = false, replyTargetId: Int? = nil,
                comments: [PrConversationComment] = []) {
        self.id = id; self.path = path; self.line = line
        self.isResolved = isResolved; self.isOutdated = isOutdated
        self.replyTargetId = replyTargetId; self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, line, isResolved, isOutdated, replyTargetId, comments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        isOutdated = try c.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false
        replyTargetId = try c.decodeIfPresent(Int.self, forKey: .replyTargetId)
        comments = try c.decodeIfPresent([PrConversationComment].self, forKey: .comments) ?? []
    }
}

// MARK: - the timeline

/// One entry of the merged timeline, in the order the core put it in. Inline threads
/// are not entries of their own: they travel with the review that opened them.
public enum PrTimelineItem: Decodable, Sendable, Equatable, Identifiable {
    case comment(PrConversationComment, id: String, createdAt: Int?)
    case review(PrReviewItem, threadGroups: [PrThreadGroup], id: String, createdAt: Int?)
    case commit(PrCommit, id: String, createdAt: Int?)

    /// Namespaced by the core, so a comment, a review and a commit can never collide
    /// even if GitHub handed back overlapping node ids.
    public var id: String {
        switch self {
        case .comment(_, let id, _), .review(_, _, let id, _), .commit(_, let id, _): return id
        }
    }

    public var createdAt: Int? {
        switch self {
        case .comment(_, _, let at), .review(_, _, _, let at), .commit(_, _, let at): return at
        }
    }

    public var created: Date? { millis(createdAt) }

    private enum CodingKeys: String, CodingKey {
        case kind, id, createdAt, comment, review, threadGroups, commit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let at = try c.decodeIfPresent(Int.self, forKey: .createdAt)
        switch kind {
        case "comment":
            self = .comment(try c.decode(PrConversationComment.self, forKey: .comment),
                            id: id, createdAt: at)
        case "review":
            self = .review(try c.decode(PrReviewItem.self, forKey: .review),
                           threadGroups: try c.decodeIfPresent([PrThreadGroup].self,
                                                               forKey: .threadGroups) ?? [],
                           id: id, createdAt: at)
        case "commit":
            self = .commit(try c.decode(PrCommit.self, forKey: .commit), id: id, createdAt: at)
        default:
            // A kind this build has no card for. Refused rather than skipped silently,
            // because the caller decodes a whole timeline and a hole in the middle of
            // one reads as a conversation with something missing from it.
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown timeline item kind `\(kind)`")
        }
    }
}

/// A PR's conversation, merged into the chronology it is read in.
///
/// The body of `GET /api/pr/timeline`: the header state, the PR's own description, the
/// items in order, and the raw threads behind them.
public struct PrTimeline: Decodable, Sendable, Equatable {
    /// OPEN / CLOSED / MERGED, upper-cased, for the header chip.
    public let state: String
    /// The PR's own description as raw markdown; empty when it has none.
    public let body: String
    public let items: [PrTimelineItem]
    /// Every inline thread on the PR, including ones no review in `items` opened.
    public let threads: [PrReviewThread]

    public init(state: String = "", body: String = "", items: [PrTimelineItem] = [],
                threads: [PrReviewThread] = []) {
        self.state = state; self.body = body; self.items = items; self.threads = threads
    }

    private enum CodingKeys: String, CodingKey { case state, body, items, threads }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        items = try c.decodeIfPresent([PrTimelineItem].self, forKey: .items) ?? []
        threads = try c.decodeIfPresent([PrReviewThread].self, forKey: .threads) ?? []
    }
}

// MARK: - the checks

/// The coarse outcome a checks row draws: green tick, red cross, orange clock, grey
/// dash. Decided by the core so the icon and the "is CI red" answer cannot disagree.
public enum PrCheckOutcome: String, Codable, Sendable, Equatable {
    case pass, fail, pending, skipped
}

/// One CI check, with its outcome already collapsed out of gh's bucket/state pair.
public struct PrCheckRow: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let state: String
    public let bucket: String
    public let link: String
    public let outcome: PrCheckOutcome
    public var id: String { "\(name)|\(link)" }

    /// True when this check counts as failed. Read off the outcome rather than
    /// recomputed: the core decides `fail` for exactly the runs `failed` means.
    public var failed: Bool { outcome == .fail }

    public init(name: String = "", state: String = "", bucket: String = "",
                link: String = "", outcome: PrCheckOutcome) {
        self.name = name; self.state = state; self.bucket = bucket
        self.link = link; self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey { case name, state, bucket, link, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        outcome = try c.decodeIfPresent(PrCheckOutcome.self, forKey: .outcome) ?? .pending
    }
}

/// Milliseconds since the epoch as a `Date`, for the views that want one.
private func millis(_ ms: Int?) -> Date? {
    ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
}
