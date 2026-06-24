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
                assignees: ["octocat", "hubber"]),
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
