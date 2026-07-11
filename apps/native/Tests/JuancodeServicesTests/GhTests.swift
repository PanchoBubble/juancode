import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Ported faithfully from `apps/server/src/gh.test.ts`. The TS suite only exercises
/// the two pure functions (`rollupChecks`, `parsePrs`) — it never spawns `gh` — so
/// no binary mocking is needed: we call the internal functions directly via
/// `@testable import` and assert on the rolled-up `PrChecks` / mapped `PullRequest`.

final class RollupChecksTests: XCTestCase {
    func testReturnsNoneForEmptyOrMissingChecks() {
        XCTAssertEqual(rollupChecks(nil), .none)
        XCTAssertEqual(rollupChecks([]), .none)
    }

    func testReturnsFailingWhenAnyCheckRunConcludedInFailure() {
        XCTAssertEqual(
            rollupChecks([
                RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
                RollupCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
            ]),
            .failing)
    }

    func testReturnsFailingForAFailedLegacyStatusContext() {
        XCTAssertEqual(
            rollupChecks([RollupCheck(status: nil, conclusion: nil, state: "FAILURE")]),
            .failing)
    }

    func testReturnsPendingWhenARunIsStillInProgressAndNoneFailed() {
        XCTAssertEqual(
            rollupChecks([
                RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
                RollupCheck(status: "IN_PROGRESS", conclusion: nil, state: nil),
            ]),
            .pending)
    }

    func testReturnsPendingForAPendingStatusContext() {
        XCTAssertEqual(
            rollupChecks([RollupCheck(status: nil, conclusion: nil, state: "PENDING")]),
            .pending)
    }

    func testReturnsPassingWhenEverythingConcludedSuccessfully() {
        XCTAssertEqual(
            rollupChecks([
                RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
                RollupCheck(status: nil, conclusion: nil, state: "SUCCESS"),
            ]),
            .passing)
    }

    func testPrioritisesFailingOverPending() {
        XCTAssertEqual(
            rollupChecks([
                RollupCheck(status: "IN_PROGRESS", conclusion: nil, state: nil),
                RollupCheck(status: "COMPLETED", conclusion: "ERROR", state: nil),
            ]),
            .failing)
    }
}

final class ParsePrsTests: XCTestCase {
    func testMapsGhFieldsOntoTheWireShapeAndRollsUpChecks() {
        let out = parsePrs([
            RawPr(
                number: 42,
                title: "Fix login",
                url: "https://github.com/o/r/pull/42",
                headRefName: "fix-login",
                isDraft: false,
                statusCheckRollup: [RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil)],
                author: RawPrAuthor(login: "octocat"),
                assignees: [RawPrAuthor(login: "octocat"), RawPrAuthor(login: nil), RawPrAuthor(login: "hubber")]),
            RawPr(
                number: 7,
                title: "WIP toggle",
                url: "https://github.com/o/r/pull/7",
                headRefName: "toggle",
                isDraft: true,
                statusCheckRollup: nil,
                author: nil),
        ])
        XCTAssertEqual(out, [
            PullRequest(
                number: 42,
                title: "Fix login",
                url: "https://github.com/o/r/pull/42",
                branch: "fix-login",
                draft: false,
                checks: .passing,
                author: "octocat",
                assignees: ["octocat", "hubber"],
                checkCount: 1,
                passedCount: 1),
            PullRequest(
                number: 7,
                title: "WIP toggle",
                url: "https://github.com/o/r/pull/7",
                branch: "toggle",
                draft: true,
                checks: .none,
                author: ""),
        ])
    }
}

/// CI-check parsing + run-id extraction backing the PR CI-log reader (juancode-49w).
/// Pure functions only — no `gh` is spawned.
final class PrChecksTests: XCTestCase {
    func testParseCheckRunsMapsFieldsAndNormalisesCase() {
        let json = """
        [
          {"name":"build","state":"SUCCESS","bucket":"pass",
           "link":"https://github.com/o/r/actions/runs/100/job/1"},
          {"name":"test","state":"failure","bucket":"Fail",
           "link":"https://github.com/o/r/actions/runs/101/job/2"}
        ]
        """
        let runs = parseCheckRuns(json)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].name, "build")
        XCTAssertEqual(runs[0].state, "SUCCESS")
        XCTAssertEqual(runs[0].bucket, "pass")
        XCTAssertFalse(runs[0].failed)
        // state/bucket are normalised (upper/lower) so `failed` is robust.
        XCTAssertEqual(runs[1].state, "FAILURE")
        XCTAssertEqual(runs[1].bucket, "fail")
        XCTAssertTrue(runs[1].failed)
    }

    func testParseCheckRunsHandlesEmptyAndGarbage() {
        XCTAssertTrue(parseCheckRuns("").isEmpty)
        XCTAssertTrue(parseCheckRuns("not json").isEmpty)
        XCTAssertTrue(parseCheckRuns("[]").isEmpty)
    }

    func testRunIdFromActionsLink() {
        XCTAssertEqual(
            runIdFromCheckLink("https://github.com/o/r/actions/runs/123456/job/789"),
            "123456")
        XCTAssertEqual(
            runIdFromCheckLink("https://github.com/o/r/actions/runs/42"),
            "42")
    }

    func testRunIdFromNonActionsLinkIsNil() {
        XCTAssertNil(runIdFromCheckLink("https://example.com/ci/build/9"))
        XCTAssertNil(runIdFromCheckLink(""))
    }
}

/// Unresolved-review-thread ("active comments") count backing the PR-list badge.
/// Pure functions only — no `gh` is spawned.
final class UnresolvedThreadTests: XCTestCase {
    func testParsePrsCarriesCheckCount() {
        let out = parsePrs([
            RawPr(number: 1, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: [
                    RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
                    RollupCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
                  ], author: nil),
            RawPr(number: 2, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: nil, author: nil),
        ])
        XCTAssertEqual(out[0].checkCount, 2)
        XCTAssertEqual(out[0].passedCount, 1) // one SUCCESS, one FAILURE
        XCTAssertEqual(out[1].checkCount, 0)
        XCTAssertEqual(out[1].passedCount, 0)
    }

    func testCountsPassedChecksExcludingPendingAndFailing() {
        let checks = [
            RollupCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
            RollupCheck(status: "COMPLETED", conclusion: "SKIPPED", state: nil),
            RollupCheck(status: "COMPLETED", conclusion: "NEUTRAL", state: nil),
            RollupCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
            RollupCheck(status: "IN_PROGRESS", conclusion: nil, state: nil),
            RollupCheck(status: nil, conclusion: nil, state: "PENDING"),
            RollupCheck(status: nil, conclusion: nil, state: "SUCCESS"),
        ]
        // SUCCESS, SKIPPED, NEUTRAL, legacy-SUCCESS state = 4 passed; FAILURE +
        // IN_PROGRESS + PENDING excluded.
        XCTAssertEqual(countPassedChecks(checks), 4)
        XCTAssertEqual(countPassedChecks(nil), 0)
        XCTAssertEqual(countPassedChecks([]), 0)
    }

    func testRepoSlugFromPrUrl() {
        let slug = repoSlug(fromPrUrl: "https://github.com/owner-x/repo.y/pull/42")
        XCTAssertEqual(slug?.owner, "owner-x")
        XCTAssertEqual(slug?.name, "repo.y")
        XCTAssertNil(repoSlug(fromPrUrl: "https://example.com/o/r/pull/1"))
        XCTAssertNil(repoSlug(fromPrUrl: ""))
    }

    func testParseUnresolvedThreadCounts() {
        let json = """
        {"data":{"repository":{"pullRequests":{"nodes":[
          {"number":10,"reviewThreads":{"nodes":[
            {"isResolved":false},{"isResolved":true},{"isResolved":false}]}},
          {"number":11,"reviewThreads":{"nodes":[]}},
          {"number":12,"reviewThreads":{"nodes":[{"isResolved":true}]}}
        ]}}}}
        """
        let counts = parseUnresolvedThreadCounts(json)
        XCTAssertEqual(counts[10], 2)
        XCTAssertEqual(counts[11], 0)
        XCTAssertEqual(counts[12], 0)
    }

    func testParseUnresolvedThreadCountsHandlesGarbage() {
        XCTAssertTrue(parseUnresolvedThreadCounts("").isEmpty)
        XCTAssertTrue(parseUnresolvedThreadCounts("not json").isEmpty)
        XCTAssertTrue(parseUnresolvedThreadCounts("{}").isEmpty)
    }

    func testMergeUnresolvedCounts() {
        let prs = [
            PullRequest(number: 10, title: "a", url: "u", branch: "b",
                        draft: false, checks: .passing, author: ""),
            PullRequest(number: 11, title: "b", url: "u", branch: "b",
                        draft: false, checks: .passing, author: ""),
        ]
        let merged = mergeUnresolvedCounts(prs, counts: [10: 3])
        XCTAssertEqual(merged[0].unresolvedComments, 3)
        // PR without an entry keeps its default (0).
        XCTAssertEqual(merged[1].unresolvedComments, 0)
    }

    func testPrBackfillQueryBuildsScopedQualifiers() {
        XCTAssertEqual(prBackfillQuery(mine: true, assigned: false, query: "", viewer: "octocat"),
                       "state:open author:octocat")
        XCTAssertEqual(prBackfillQuery(mine: false, assigned: true, query: "", viewer: "octocat"),
                       "state:open assignee:octocat")
        XCTAssertEqual(prBackfillQuery(mine: true, assigned: true, query: " 403 ", viewer: "octocat"),
                       "state:open author:octocat assignee:octocat 403")
        XCTAssertEqual(prBackfillQuery(mine: false, assigned: false, query: "fix flake", viewer: ""),
                       "state:open fix flake")
    }

    func testPrBackfillQueryNilWhenNothingScopesBeyondFirehose() {
        // No filters at all → the base list already covers the view.
        XCTAssertNil(prBackfillQuery(mine: false, assigned: false, query: "", viewer: "octocat"))
        // Whitespace-only text is not a query.
        XCTAssertNil(prBackfillQuery(mine: false, assigned: false, query: "   ", viewer: "octocat"))
        // Mine/Assigned can't scope while the viewer login is unknown — firing
        // would just repeat the unscoped firehose page.
        XCTAssertNil(prBackfillQuery(mine: true, assigned: true, query: "", viewer: ""))
    }

    func testMergePrListsUnionsByNumberNewestFirst() {
        let base = [
            PullRequest(number: 50, title: "new", url: "u", branch: "b",
                        draft: false, checks: .passing, author: "me", unresolvedComments: 4),
            PullRequest(number: 40, title: "mid", url: "u", branch: "b",
                        draft: false, checks: .passing, author: "me"),
        ]
        let extra = [
            // Already present: base entry (with its unresolvedComments) must win.
            PullRequest(number: 50, title: "new", url: "u", branch: "b",
                        draft: false, checks: .passing, author: "me"),
            // Genuinely new, older than the firehose cap: folds in.
            PullRequest(number: 12, title: "old", url: "u", branch: "b",
                        draft: false, checks: .passing, author: "me"),
        ]
        let merged = mergePrLists(base, extra)
        XCTAssertEqual(merged.map(\.number), [50, 40, 12])
        // Existing enriched entry preserved, not clobbered by the backfill copy.
        XCTAssertEqual(merged[0].unresolvedComments, 4)
    }

    func testSortPrsTrackedFirstIsStableWithinBands() {
        func pr(_ n: Int) -> PullRequest {
            PullRequest(number: n, title: "t\(n)", url: "u", branch: "b",
                        draft: false, checks: .passing, author: "me")
        }
        let prs = [pr(50), pr(40), pr(30), pr(20)]
        let tracked: Set<Int> = [40, 20]
        let ordered = sortPrsTrackedFirst(prs) { tracked.contains($0.number) }
        // Tracked PRs lead; both bands keep their incoming (newest-first) order.
        XCTAssertEqual(ordered.map(\.number), [40, 20, 50, 30])
        // No tracked PRs → the list is unchanged.
        XCTAssertEqual(sortPrsTrackedFirst(prs) { _ in false }.map(\.number), [50, 40, 30, 20])
    }
}
