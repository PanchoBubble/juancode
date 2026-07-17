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
