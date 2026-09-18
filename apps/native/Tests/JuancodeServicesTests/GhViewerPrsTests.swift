import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The viewer queue behind Tools → GitHub. Everything here is the pure half —
/// parsing one `gh api graphql` payload into rows, grouping them, and counting the
/// ones that want something from you. The fetch itself is one `gh` shell-out and is
/// not exercised (same contract as `GhTests`).

/// A payload shaped exactly like gh's, with the two aliased search buckets.
private func payload(mine: [String] = [], reviews: [String] = []) -> String {
    """
    {"data":{"mine":{"nodes":[\(mine.joined(separator: ","))]},
             "reviews":{"nodes":[\(reviews.joined(separator: ","))]}}}
    """
}

/// One PullRequest node. `extra` appends raw JSON fields (checks, threads, …).
private func node(_ number: Int, repo: String = "acme/app", title: String = "A change",
                  author: String = "me", extra: String = "") -> String {
    """
    {"number":\(number),"title":"\(title)","url":"https://github.com/\(repo)/pull/\(number)",
     "isDraft":false,"createdAt":"2026-09-01T10:00:00Z","headRefName":"feat/x",
     "additions":10,"deletions":2,"changedFiles":3,
     "repository":{"nameWithOwner":"\(repo)"},"author":{"login":"\(author)"},
     "assignees":{"nodes":[]},"reviewDecision":null\(extra)}
    """
}

final class ParseViewerPrsTests: XCTestCase {
    func testParsesBothBucketsWithTheirReasons() {
        let rows = parseViewerPrs(payload(mine: [node(1)], reviews: [node(2, author: "someone")]))
        XCTAssertEqual(rows?.map(\.pr.number), [1, 2])
        XCTAssertEqual(rows?.map(\.reason), [.mine, .reviewRequested])
        XCTAssertEqual(rows?.first?.repo, "acme/app")
        XCTAssertEqual(rows?.first?.id, "acme/app#1")
    }

    func testAPrInBothBucketsIsListedOnceAsYours() {
        let rows = parseViewerPrs(payload(mine: [node(7)], reviews: [node(7)]))
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?.reason, .mine)
    }

    func testSameNumberInDifferentReposAreDifferentRows() {
        let rows = parseViewerPrs(payload(mine: [node(7, repo: "acme/app"), node(7, repo: "acme/web")]))
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(Set(rows?.map(\.repo) ?? []), ["acme/app", "acme/web"])
    }

    func testRollsUpTheHeadCommitsChecks() {
        let checks = """
        ,"rollup":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
          {"status":"COMPLETED","conclusion":"SUCCESS"},
          {"status":"COMPLETED","conclusion":"FAILURE"},
          {"state":"SUCCESS"}]}}}}]}
        """
        let rows = parseViewerPrs(payload(mine: [node(1, extra: checks)]))
        XCTAssertEqual(rows?.first?.pr.checks, .failing)
        XCTAssertEqual(rows?.first?.pr.checkCount, 3)
        XCTAssertEqual(rows?.first?.pr.passedCount, 2)
    }

    func testCountsOnlyUnresolvedReviewThreads() {
        let threads = """
        {"number":3,"url":"https://github.com/acme/app/pull/3","title":"t",
         "repository":{"nameWithOwner":"acme/app"},
         "reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true},{"isResolved":false}]}}
        """
        let rows = parseViewerPrs(payload(mine: [threads]))
        XCTAssertEqual(rows?.first?.pr.unresolvedComments, 2)
    }

    func testReviewRequestsCarryUsersAndTeams() {
        let requests = """
        ,"reviewRequests":{"nodes":[{"requestedReviewer":{"login":"me"}},
                                    {"requestedReviewer":{"slug":"platform"}}]}
        """
        let rows = parseViewerPrs(payload(reviews: [node(4, extra: requests)]))
        XCTAssertEqual(rows?.first?.pr.reviewRequests, ["me", "platform"])
    }

    /// The fragment is on PullRequest but the search is over issues: a non-PR hit
    /// comes back as `{}` and must cost that row only.
    func testSkipsNodesWithoutPrIdentity() {
        let rows = parseViewerPrs(payload(mine: ["{}", node(9)]))
        XCTAssertEqual(rows?.map(\.pr.number), [9])
    }

    func testFallsBackToTheRepoSlugInTheUrl() {
        let noRepo = """
        {"number":5,"title":"t","url":"https://github.com/acme/web/pull/5"}
        """
        XCTAssertEqual(parseViewerPrs(payload(mine: [noRepo]))?.first?.repo, "acme/web")
    }

    func testAnEmptyQueueIsAnAnswerAndGarbageIsNot() {
        XCTAssertEqual(parseViewerPrs(payload())?.count, 0)
        XCTAssertNil(parseViewerPrs("not json"))
        XCTAssertNil(parseViewerPrs("""
        {"errors":[{"message":"Bad credentials"}]}
        """))
    }
}

final class ViewerPrQueueShapeTests: XCTestCase {
    private func row(_ number: Int, repo: String, reason: ViewerPrReason,
                     author: String = "me", checks: PrChecks = .passing,
                     reviewDecision: String? = nil, unresolved: Int = 0,
                     reviewRequests: [String] = []) -> ViewerPr {
        ViewerPr(
            pr: PullRequest(number: number, title: "t",
                            url: "https://github.com/\(repo)/pull/\(number)",
                            branch: "b", draft: false, checks: checks, author: author,
                            unresolvedComments: unresolved, reviewDecision: reviewDecision,
                            reviewRequests: reviewRequests),
            repo: repo, reason: reason)
    }

    func testGroupsByRepoKeepingFirstAppearanceOrder() {
        let grouped = groupViewerPrsByRepo([
            row(1, repo: "acme/web", reason: .mine),
            row(2, repo: "acme/app", reason: .mine),
            row(3, repo: "acme/web", reason: .reviewRequested, author: "other"),
        ])
        XCTAssertEqual(grouped.map(\.repo), ["acme/web", "acme/app"])
        XCTAssertEqual(grouped.first?.rows.map(\.pr.number), [1, 3])
    }

    func testNeedingYouCountsReviewsAndYourOwnTrouble() {
        let result = ViewerPrResult(available: true, rows: [
            row(1, repo: "acme/app", reason: .mine),                       // quiet
            row(2, repo: "acme/app", reason: .mine, checks: .failing),     // red CI
            row(3, repo: "acme/app", reason: .mine, reviewDecision: "CHANGES_REQUESTED"),
            row(4, repo: "acme/app", reason: .mine, unresolved: 2),
            row(5, repo: "acme/app", reason: .reviewRequested, author: "other",
                reviewRequests: ["me"]),
        ], viewer: "me")
        XCTAssertEqual(viewerPrsNeedingYou(result), 4)
    }

    /// Without a viewer login nothing can be scored against you, and an unavailable
    /// queue must not claim urgency it hasn't measured.
    func testNeedingYouIsZeroWithoutAViewerOrAnAnswer() {
        let rows = [row(1, repo: "acme/app", reason: .reviewRequested, author: "other")]
        XCTAssertEqual(viewerPrsNeedingYou(ViewerPrResult(available: true, rows: rows)), 0)
        XCTAssertEqual(
            viewerPrsNeedingYou(ViewerPrResult(available: false, rows: rows, viewer: "me")), 0)
    }

    func testTheTwoSearchesScopeToOpenPrsAndTheViewer() {
        XCTAssertTrue(viewerPrSearch(mine: true).contains("author:@me"))
        XCTAssertTrue(viewerPrSearch(mine: false).contains("review-requested:@me"))
        for q in [viewerPrSearch(mine: true), viewerPrSearch(mine: false)] {
            XCTAssertTrue(q.contains("is:open"))
            XCTAssertTrue(q.contains("is:pr"))
        }
    }
}

/// The one test that actually spends a `gh` round trip. Off by default (CI must not
/// depend on GitHub, and it needs a logged-in `gh`): run it with
/// `JUANCODE_LIVE_GH=1 swift test --filter LiveViewerPrs`. It exists because the
/// query is the half unit tests can't check — a field GitHub renames breaks the
/// queue with a payload that still parses to an empty list.
final class LiveViewerPrsTests: XCTestCase {
    func testTheRealSearchAnswersAndParses() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUANCODE_LIVE_GH"] == "1",
                          "live gh test: set JUANCODE_LIVE_GH=1")
        let result = await getViewerPrs()
        XCTAssertTrue(result.available, result.error ?? "no error reported")
        XCTAssertFalse(result.viewer.isEmpty, "gh reported no viewer login")
        // Nothing here asserts a non-empty queue — an empty plate is a valid answer.
        for row in result.rows {
            XCTAssertGreaterThan(row.pr.number, 0)
            XCTAssertTrue(row.pr.url.contains("/pull/"), row.pr.url)
            XCTAssertTrue(row.repo.contains("/"), row.repo)
        }
    }
}
