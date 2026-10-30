import Foundation
import Testing
import JuancodeCore
@testable import JuancodeDesktop

@Suite struct ReviewDraftStoreTests {
    @Test func notesDestinationsAndPrIdentitySurviveReopeningTheStore() throws {
        let suite = "ReviewDraftStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let comment = ReviewComment(id: "note", path: "src/main.swift", startLabel: "12",
                                    endLabel: "12", endKey: "n12", excerpt: ["+line"],
                                    text: "Please fix this\nwith the existing helper", forGitHub: true)
        let pr = PullRequest(number: 42, title: "Fix widgets",
                             url: "https://github.com/acme/widgets/pull/42", branch: "fix",
                             draft: false, checks: .passing, author: "author")
        let draft = SavedReviewDraft(comments: [comment], base: .main,
                                     cwd: "github-pr:\(pr.url)", pr: pr, agentSessionId: "chosen")
        let store = ReviewDraftStore(defaults: defaults)
        #expect(try store.load().isEmpty)
        try store.save(["pr:42": draft])
        let reopened = ReviewDraftStore(defaults: defaults)
        #expect(try reopened.load() == ["pr:42": draft])
        // Successful delivery/removing the last note must not resurrect it on restart.
        try reopened.save([:])
        #expect(try store.load().isEmpty)
    }

    @Test func unreadableSavedWorkIsReportedAndNotChangedByLoading() throws {
        let suite = "ReviewDraftStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = Data("unreadable draft".utf8)
        defaults.set(invalid, forKey: "diffReview.savedDrafts.v1")
        #expect(throws: (any Error).self) { try ReviewDraftStore(defaults: defaults).load() }
        #expect(defaults.data(forKey: "diffReview.savedDrafts.v1") == invalid)
    }
}
