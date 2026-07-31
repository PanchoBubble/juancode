import Foundation

/// Pure presentation helpers for the GitHub view's PR detail pane: merging a
/// conversation's issue comments + review verdicts into one chronological
/// timeline, and collapsing a CI check run's gh bucket/state pair into the
/// coarse outcome the row iconography needs. No UI, no `gh` — unit-testable.

// MARK: - conversation timeline

/// One entry of the merged conversation timeline: an issue comment or a review
/// verdict. Inline review threads stay grouped by `path:line` and are rendered
/// separately, so they're deliberately not part of this merge.
public enum PrTimelineItem: Sendable, Equatable, Identifiable {
    case comment(PrConversationComment)
    case review(PrReviewItem)
    case commit(PrCommit)

    /// Namespaced so a comment, a review, and a commit can never collide even if
    /// GitHub ever handed back overlapping node ids.
    public var id: String {
        switch self {
        case .comment(let c): return "comment:\(c.id)"
        case .review(let r): return "review:\(r.id)"
        case .commit(let c): return "commit:\(c.oid)"
        }
    }

    public var createdAt: Date? {
        switch self {
        case .comment(let c): return c.createdAt
        case .review(let r): return r.createdAt
        case .commit(let c): return c.committedDate
        }
    }
}

/// Merge issue comments + review verdicts + commits into one timeline,
/// chronological by `createdAt`. Undated items (garbage timestamps parse to nil)
/// sort last; ties and undated runs keep their input order (comments, then
/// reviews, then commits) so the result is deterministic.
public func prTimeline(comments: [PrConversationComment], reviews: [PrReviewItem],
                       commits: [PrCommit] = []) -> [PrTimelineItem] {
    let items = comments.map(PrTimelineItem.comment)
        + reviews.map(PrTimelineItem.review)
        + commits.map(PrTimelineItem.commit)
    return items.enumerated().sorted { a, b in
        switch (a.element.createdAt, b.element.createdAt) {
        case let (x?, y?): return x != y ? x < y : a.offset < b.offset
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.offset < b.offset
        }
    }.map(\.element)
}

/// Convenience overload over a fetched conversation.
public func prTimeline(_ conversation: PrConversation) -> [PrTimelineItem] {
    prTimeline(comments: conversation.issueComments, reviews: conversation.reviews,
               commits: conversation.commits)
}

/// The timeline with review events that would render as an empty card dropped —
/// see `reviewHasVisibleContent`. Comments and commits always survive.
public func prVisibleTimeline(_ conversation: PrConversation) -> [PrTimelineItem] {
    prTimeline(conversation).filter { item in
        guard case .review(let r) = item else { return true }
        return reviewHasVisibleContent(review: r, threads: conversation.threads)
    }
}

// MARK: - inline review threads

/// One inline review thread the way the conversation renders it: the anchor
/// (`path:line`), its resolution state, the id a reply must target, and every
/// comment in it — the root first, then the replies. `comments` is never empty.
public struct PrThreadGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String?
    public let line: Int?
    public let isResolved: Bool
    public let isOutdated: Bool
    public let replyTargetId: Int?
    public let comments: [PrConversationComment]

    public init(id: String, path: String?, line: Int?, isResolved: Bool,
                isOutdated: Bool, replyTargetId: Int?, comments: [PrConversationComment]) {
        self.id = id; self.path = path; self.line = line
        self.isResolved = isResolved; self.isOutdated = isOutdated
        self.replyTargetId = replyTargetId; self.comments = comments
    }

    /// The comment the thread hangs off — the one carrying the diff hunk.
    public var root: PrConversationComment? { comments.first }
    /// Everything after the root: the back-and-forth.
    public var replies: [PrConversationComment] { Array(comments.dropFirst()) }
}

/// The inline threads a review *starts*, each with its full comment list.
///
/// A review comment that only replies to a thread an earlier review opened yields
/// nothing here: it renders nested under that thread's root instead. Without that,
/// every turn of a back-and-forth became its own card, re-printing the same
/// `path:line` and the same diff hunk — the thread was on screen three times over
/// with no indication the three cards were one conversation.
public func reviewThreadGroups(review: PrReviewItem,
                               threads: [PrReviewThread]) -> [PrThreadGroup] {
    var out: [PrThreadGroup] = []
    for c in review.comments {
        guard let t = threads.first(where: { t in t.comments.contains(where: { $0.id == c.id }) })
        else {
            // No thread carries it (a shape GitHub shouldn't hand back). Render it
            // alone rather than drop a real comment on the floor.
            out.append(PrThreadGroup(id: c.id, path: c.path, line: c.line,
                                     isResolved: false, isOutdated: false,
                                     replyTargetId: c.databaseId, comments: [c]))
            continue
        }
        // A reply: its root already renders the whole thread, this one included.
        guard t.comments.first?.id == c.id else { continue }
        out.append(PrThreadGroup(id: t.id, path: t.path.isEmpty ? c.path : t.path,
                                 line: t.line ?? c.line,
                                 isResolved: t.isResolved, isOutdated: t.isOutdated,
                                 replyTargetId: t.replyTargetId, comments: t.comments))
    }
    return out
}

/// Whether a review event still has anything to show once its replies have been
/// folded into their threads: a summary body, a thread it started, or a verdict
/// that says something by itself (approved / changes requested). A bare
/// `COMMENTED` review carrying only replies would render as an empty card, so the
/// timeline drops it — the replies are already visible in their threads.
public func reviewHasVisibleContent(review: PrReviewItem,
                                    threads: [PrReviewThread]) -> Bool {
    if !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if !review.reactions.isEmpty { return true }
    if !reviewThreadGroups(review: review, threads: threads).isEmpty { return true }
    switch review.state.uppercased() {
    case "COMMENTED", "PENDING", "": return false
    default: return true
    }
}

// MARK: - check outcome

/// The coarse outcome a checks row renders: green check / red x / orange
/// pending / gray skipped.
public enum PrCheckOutcome: Sendable, Equatable {
    case pass, fail, pending, skipped
}

/// Collapse a check run's gh `bucket` (pass/fail/pending/skipping/cancel) —
/// falling back to the raw `state` for older status contexts where the bucket
/// is empty — into the row outcome. Failure detection defers to
/// `PrCheckRun.failed` so the two never disagree.
public func checkOutcome(_ run: PrCheckRun) -> PrCheckOutcome {
    if run.failed { return .fail }
    switch run.bucket {
    case "pass": return .pass
    case "skipping", "cancel": return .skipped
    case "pending": return .pending
    default: break
    }
    switch run.state {
    case "SUCCESS": return .pass
    case "SKIPPED", "NEUTRAL", "CANCELLED": return .skipped
    default: return .pending
    }
}
