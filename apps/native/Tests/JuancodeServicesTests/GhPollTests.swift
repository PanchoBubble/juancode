import XCTest
import JuancodeCore
@testable import JuancodeServices

/// What is left of `GhTests.swift` after juancode-h0l6: the parse half of the four
/// `gh` probes the in-process Swift server still makes for itself. The pure list
/// shaping moved to `JuancodeCoreTests/PrTriageTests.swift` with the functions, and
/// everything that tested a call the SwiftUI app used to make — `getPrForBranch`, the
/// check runs, the diff, the writes — went with the call: those are `juancoded`'s now
/// and are covered by `juancoded_core::gh`'s own tests and by conformance 45-github.
///
/// This file dies with `GhPoll.swift`, in juancode-nqpm.

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

final class PrDiffSizeTests: XCTestCase {
    func testCarriesGhsDiffSizeOntoTheWireShape() {
        let out = parsePrs([
            RawPr(number: 42, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: nil, author: nil,
                  additions: 1200, deletions: 44, changedFiles: 9),
        ])
        XCTAssertEqual(out.first?.diffCounts,
                       DiffCounts(files: 9, additions: 1200, deletions: 44))
    }

    func testNoDiffCountsWhenGhDidntReportThem() {
        let out = parsePrs([
            RawPr(number: 42, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: nil, author: nil),
        ])
        XCTAssertNil(out.first?.diffCounts,
                     "an unsized PR must leave the badge hidden, not show +0 −0")
    }

    /// A client that predates the diff fields still sends a `PullRequest` over the
    /// `trackPr` frame — decoding it must not fail.
    func testDecodesAPayloadWithoutTheDiffFields() throws {
        let json = """
        {"number":7,"title":"t","url":"u","branch":"b","draft":false,"checks":"none",
         "checkCount":0,"passedCount":0,"unresolvedComments":0,"author":"octocat",
         "assignees":[],"reviewRequests":[]}
        """
        let pr = try JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
        XCTAssertEqual(pr.number, 7)
        XCTAssertNil(pr.diffCounts)
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
}

final class ParsePrsReviewFieldsTests: XCTestCase {
    func testCarriesCreatedAtReviewDecisionAndRequestedReviewers() {
        let out = parsePrs([
            RawPr(number: 9, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: nil, author: RawPrAuthor(login: "octocat"),
                  createdAt: "2026-08-01T09:00:00Z",
                  reviewDecision: "CHANGES_REQUESTED",
                  reviewRequests: [RawReviewRequest(login: "hubber"),
                                   RawReviewRequest(login: nil, slug: "platform"),
                                   RawReviewRequest(login: nil, slug: nil, name: nil)]),
        ])
        XCTAssertEqual(out.first?.createdAt, "2026-08-01T09:00:00Z")
        XCTAssertEqual(out.first?.reviewDecisionKind, .changesRequested)
        XCTAssertEqual(out.first?.reviewRequests, ["hubber", "platform"])
    }

    func testUnrecognisedReviewDecisionResolvesToNilWithoutLosingTheRawValue() {
        let out = parsePrs([
            RawPr(number: 9, title: "t", url: "u", headRefName: "b", isDraft: false,
                  statusCheckRollup: nil, author: nil, reviewDecision: "SOMETHING_NEW"),
        ])
        XCTAssertNil(out.first?.reviewDecisionKind)
        XCTAssertEqual(out.first?.reviewDecision, "SOMETHING_NEW")
    }
}
