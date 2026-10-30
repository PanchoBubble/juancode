import Foundation
import JuancodeCore

/// Only the user's work is stored; diffs and GitHub threads are fetched again.
public struct SavedReviewDraft: Codable, Equatable, Sendable {
    public var comments: [ReviewComment]
    public var base: ReviewBase
    public var cwd: String?
    public var pr: PullRequest?
    public var agentSessionId: String?

    public init(comments: [ReviewComment], base: ReviewBase, cwd: String?,
                pr: PullRequest?, agentSessionId: String?) {
        self.comments = comments
        self.base = base
        self.cwd = cwd
        self.pr = pr
        self.agentSessionId = agentSessionId
    }
}

public struct ReviewDraftStore {
    private let defaults: UserDefaults
    private let key = "diffReview.savedDrafts.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() throws -> [String: SavedReviewDraft] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: SavedReviewDraft].self, from: data)
    }

    public func save(_ drafts: [String: SavedReviewDraft]) throws {
        defaults.set(try JSONEncoder().encode(drafts), forKey: key)
    }
}
