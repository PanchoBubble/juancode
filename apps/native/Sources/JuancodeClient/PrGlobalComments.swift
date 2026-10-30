import Foundation

/// A selection id that cannot collide with a filesystem path in the diff review.
public let prGlobalCommentsPath = "\u{0}pr-global-comments"

/// A PR-level conversation entry: an issue comment or a review's summary body.
public struct PrGlobalComment: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case comment
        case review(state: String)
    }

    public let id: String
    public let kind: Kind
    public let author: String
    public let body: String
    public let createdAt: Int?
    public let url: String

    public init(id: String, kind: Kind, author: String, body: String,
                createdAt: Int? = nil, url: String = "") {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// Keep the timeline's chronology, but leave commits and file-anchored threads in
/// their existing views. Reviews whose summary is blank contribute nothing here.
public func prGlobalComments(_ timeline: PrTimeline?) -> [PrGlobalComment] {
    guard let timeline else { return [] }
    return timeline.items.compactMap { item in
        switch item {
        case .comment(let comment, let id, let createdAt):
            return PrGlobalComment(id: id, kind: .comment, author: comment.author,
                                   body: comment.body, createdAt: createdAt, url: comment.url)
        case .review(let review, _, let id, let createdAt):
            guard !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PrGlobalComment(id: id, kind: .review(state: review.state),
                                   author: review.author, body: review.body,
                                   createdAt: createdAt, url: review.url)
        case .commit:
            return nil
        }
    }
}

/// gt/gT visits the PR-wide pane as well as each real file. Session reviews pass
/// `includePrComments: false` and retain their original order.
public func reviewSelectionOrder(_ filePaths: [String], includePrComments: Bool) -> [String] {
    includePrComments ? [prGlobalCommentsPath] + filePaths : filePaths
}

/// Preserve the file-first default, except when a PR has no files to select.
public func reviewInitialSelection(_ filePaths: [String], includePrComments: Bool) -> String? {
    filePaths.first ?? (includePrComments ? prGlobalCommentsPath : nil)
}
