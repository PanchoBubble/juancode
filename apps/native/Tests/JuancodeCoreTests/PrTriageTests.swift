import XCTest
@testable import JuancodeCore

/// The half of a PR list that must not be a round trip: what a filter box matches as
/// you type, which rows a chip is showing, and how an age reads. Moved here from
/// `GhTests.swift` with `Gh.swift` (juancode-h0l6) — the fetching went to the daemon,
/// these did not, because they run per keystroke over a list already in hand.

private func pr(_ n: Int, author: String = "octocat", assignees: [String] = [],
                checks: PrChecks = .passing, unresolved: Int = 0, draft: Bool = false,
                decision: String? = nil, requests: [String] = [],
                title: String = "", branch: String = "b",
                url: String = "u") -> PullRequest {
    PullRequest(number: n, title: title.isEmpty ? "t\(n)" : title, url: url, branch: branch,
                draft: draft, checks: checks, author: author, assignees: assignees,
                unresolvedComments: unresolved, reviewDecision: decision,
                reviewRequests: requests)
}

final class PrAgeLabelTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z")!

    func testFormatsEachCoarseBucket() {
        XCTAssertEqual(prAgeLabel("2026-08-05T11:35:00Z", now: now), "25m")
        XCTAssertEqual(prAgeLabel("2026-08-05T08:00:00Z", now: now), "4h")
        XCTAssertEqual(prAgeLabel("2026-08-03T12:00:00Z", now: now), "2d")
        // Past a fortnight it switches to weeks.
        XCTAssertEqual(prAgeLabel("2026-07-01T12:00:00Z", now: now), "5w")
        XCTAssertEqual(prAgeLabel("2025-01-01T12:00:00Z", now: now), "1y")
    }

    func testFloorsAtOneMinuteAndNeverGoesNegative() {
        XCTAssertEqual(prAgeLabel("2026-08-05T11:59:59Z", now: now), "1m")
        // A clock-skewed future timestamp still reads as brand new, not "-3m".
        XCTAssertEqual(prAgeLabel("2026-08-05T12:05:00Z", now: now), "1m")
    }

    func testAcceptsFractionalSecondsAndRejectsGarbage() {
        XCTAssertEqual(prAgeLabel("2026-08-05T08:00:00.123Z", now: now), "4h")
        XCTAssertNil(prAgeLabel(nil, now: now))
        XCTAssertNil(prAgeLabel("yesterday", now: now))
    }
}

final class RepoSlugTests: XCTestCase {
    func testLiftsOwnerAndNameFromAPrUrl() {
        let slug = repoSlug(fromPrUrl: "https://github.com/owner-x/repo.y/pull/42")
        XCTAssertEqual(slug?.owner, "owner-x")
        XCTAssertEqual(slug?.name, "repo.y")
    }

    func testAnythingThatIsNotAPrUrlIsNil() {
        XCTAssertNil(repoSlug(fromPrUrl: "https://example.com/o/r/pull/1"))
        // The path shape matters, not just the host: a repo url is not a PR url.
        XCTAssertNil(repoSlug(fromPrUrl: "https://github.com/owner/repo"))
        XCTAssertNil(repoSlug(fromPrUrl: "https://github.com/owner/repo/issues/1"))
        XCTAssertNil(repoSlug(fromPrUrl: ""))
    }
}

final class PrListShapingTests: XCTestCase {
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
        var enriched = pr(50, title: "new")
        enriched.unresolvedComments = 4
        let base = [enriched, pr(40, title: "mid")]
        let extra = [
            // Already present: the base entry (with its unresolvedComments) must win.
            pr(50, title: "new"),
            // Genuinely new, older than the firehose cap: folds in.
            pr(12, title: "old"),
        ]
        let merged = mergePrLists(base, extra)
        XCTAssertEqual(merged.map(\.number), [50, 40, 12])
        XCTAssertEqual(merged[0].unresolvedComments, 4)
    }

    func testSortPrsTrackedFirstIsStableWithinBands() {
        let prs = [pr(50), pr(40), pr(30), pr(20)]
        let tracked: Set<Int> = [40, 20]
        let ordered = sortPrsTrackedFirst(prs) { tracked.contains($0.number) }
        // Tracked PRs lead; both bands keep their incoming (newest-first) order.
        XCTAssertEqual(ordered.map(\.number), [40, 20, 50, 30])
        // No tracked PRs → the list is unchanged.
        XCTAssertEqual(sortPrsTrackedFirst(prs) { _ in false }.map(\.number), [50, 40, 30, 20])
    }

    func testSortPrsBySubmitDateIsNumberDescending() {
        // PR numbers are assigned at creation, so number-desc == submit-date-desc.
        XCTAssertEqual(sortPrsBySubmitDate([pr(20), pr(50), pr(30), pr(40)]).map(\.number),
                       [50, 40, 30, 20])
    }
}

final class PrMatchesQueryTests: XCTestCase {
    private let row = pr(4821, title: "Fix login redirect", branch: "juan/fix-login")

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(prMatchesQuery(row, ""))
        XCTAssertTrue(prMatchesQuery(row, "   "))
    }

    func testMatchesTitleAuthorAndBranchCaseInsensitively() {
        XCTAssertTrue(prMatchesQuery(row, "LOGIN"))
        XCTAssertTrue(prMatchesQuery(row, "octo"))
        XCTAssertTrue(prMatchesQuery(row, "juan/fix"))
        XCTAssertFalse(prMatchesQuery(row, "logout"))
    }

    func testMatchesNumberWithOrWithoutHash() {
        XCTAssertTrue(prMatchesQuery(row, "#4821"))
        XCTAssertTrue(prMatchesQuery(row, "4821"))
        // Prefix, so a partial number finds it.
        XCTAssertTrue(prMatchesQuery(row, "48"))
        XCTAssertFalse(prMatchesQuery(row, "#99"))
        // A non-numeric "#" query can't match a number and doesn't crash.
        XCTAssertFalse(prMatchesQuery(row, "#"))
    }
}

/// The triage answer arrives decided, per folder. What is left on this side is the
/// interleave, which is the one rule that cannot move: a route that fanned out over
/// every open folder would pay fork+exec per folder in series before GitHub was asked
/// anything.
final class NeedsYouTests: XCTestCase {
    private func row(_ n: Int, _ reason: PrAttentionReason, cwd: String) -> NeedsYouRow {
        NeedsYouRow(cwd: cwd, pr: pr(n), reason: reason, label: reason.label)
    }

    func testTheFourReasonsRankInTheOrderTheCoreSpellsThem() {
        XCTAssertEqual(PrAttentionReason.allCases.map(\.rank), [0, 1, 2, 3])
        XCTAssertEqual(PrAttentionReason.ciFailing.label, "CI failing")
        // The rawValue is the wire spelling, which is NOT the label: a client that
        // printed the rawValue would draw "ciFailing" at somebody.
        XCTAssertEqual(PrAttentionReason.ciFailing.rawValue, "ciFailing")
    }

    func testDecodesTheReasonAndTheLabelTheCoreSent() throws {
        let json = """
        {"cwd":"/a","reason":"reviewRequested","label":"review requested",
         "pr":{"number":7,"title":"t","url":"u","branch":"b","draft":false,
               "checks":"passing","checkCount":0,"passedCount":0,
               "unresolvedComments":0,"author":"hubber","assignees":[],
               "reviewRequests":[]}}
        """
        let decoded = try JSONDecoder().decode(NeedsYouRow.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.reason, .reviewRequested)
        XCTAssertEqual(decoded.text, "review requested")
    }

    func testARowWithNoLabelFallsBackToTheReasonsOwnWords() {
        XCTAssertEqual(NeedsYouRow(cwd: "/a", pr: pr(1), reason: .unresolved).text,
                       "unresolved threads")
    }

    func testFoldersInterleaveByReasonThenNewestFirst() {
        let a = [row(10, .unresolved, cwd: "/a"), row(20, .ciFailing, cwd: "/a")]
        let b = [row(40, .ciFailing, cwd: "/b"), row(50, .reviewRequested, cwd: "/b")]
        let out = mergeNeedsYou([a, b])
        XCTAssertEqual(out.map(\.pr.number), [40, 20, 10, 50])
        XCTAssertEqual(out.map(\.reason), [.ciFailing, .ciFailing, .unresolved, .reviewRequested])
        XCTAssertEqual(out.first?.cwd, "/b")
    }
}

/// The viewer queue's chips. The rows and their attention come off `/api/prs/viewer`
/// already decided; the slicing is here because four chip counts off one fetch must
/// not be four requests.
final class ViewerPrQueueTests: XCTestCase {
    private func row(_ n: Int, repo: String, _ reason: ViewerPrReason,
                     attention: PrAttentionReason? = nil) -> ViewerPr {
        ViewerPr(pr: pr(n), repo: repo, reason: reason, attention: attention,
                 attentionLabel: attention?.label)
    }

    private var queue: ViewerPrResult {
        ViewerPrResult(available: true, rows: [
            row(10, repo: "o/a", .mine),
            row(20, repo: "o/a", .mine, attention: .ciFailing),
            row(30, repo: "o/b", .reviewRequested, attention: .reviewRequested),
        ], viewer: "octocat")
    }

    func testGroupsByRepoKeepingFirstAppearanceOrder() {
        let groups = groupViewerPrsByRepo(queue.rows)
        XCTAssertEqual(groups.map(\.repo), ["o/a", "o/b"])
        XCTAssertEqual(groups[0].rows.map(\.pr.number), [10, 20])
    }

    func testEachSliceListsExactlyWhatItsChipCounts() {
        for slice in ViewerPrSlice.allCases {
            XCTAssertEqual(viewerPrCount(queue, slice: slice),
                           viewerPrRows(queue, slice: slice).count, "\(slice)")
        }
        XCTAssertEqual(viewerPrCount(queue, slice: .all), 3)
        XCTAssertEqual(viewerPrCount(queue, slice: .mine), 2)
        XCTAssertEqual(viewerPrCount(queue, slice: .review), 1)
        XCTAssertEqual(viewerPrCount(queue, slice: .needsYou), 2)
        XCTAssertEqual(viewerPrsNeedingYou(queue), 2)
    }

    func testRowsPutWhatWantsYouFirstAndKeepTheQueueOrderOtherwise() {
        // CI failing outranks a review request, and the row with no attention sinks
        // to the end without being dropped.
        XCTAssertEqual(viewerPrRows(queue, slice: .all).map(\.pr.number), [20, 30, 10])
    }

    func testAFailedSearchNeverClaimsANumber() {
        let failed = ViewerPrResult(available: false, error: "gh not authenticated")
        for slice in ViewerPrSlice.allCases {
            XCTAssertEqual(viewerPrCount(failed, slice: slice), 0)
        }
        XCTAssertEqual(viewerPrsNeedingYou(failed), 0)
    }

    func testDecodesTheRowTheCoreSends() throws {
        let json = """
        {"available":true,"viewer":"octocat","rows":[
          {"repo":"o/a","reason":"reviewRequested","attention":"reviewRequested",
           "attentionLabel":"review requested",
           "pr":{"number":7,"title":"t","url":"u","branch":"b","draft":false,
                 "checks":"passing","checkCount":0,"passedCount":0,
                 "unresolvedComments":0,"author":"hubber","assignees":[],
                 "reviewRequests":[]}}]}
        """
        let decoded = try JSONDecoder().decode(ViewerPrResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.reviewing.count, 1)
        XCTAssertEqual(decoded.rows.first?.id, "o/a#7")
        XCTAssertEqual(decoded.rows.first?.attention, .reviewRequested)
        XCTAssertEqual(viewerPrsNeedingYou(decoded), 1)
    }
}
