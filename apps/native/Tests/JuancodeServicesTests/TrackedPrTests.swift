import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the tracked-PR engine (juancode-it5): the pure classifier that
/// diffs PR activity into auto-fix vs needs-decision events, the derived badge
/// state, the `gh pr view --json` parser, and the prompt builders. No `gh` spawn.

// MARK: - parsePrActivity

final class ParsePrActivityTests: XCTestCase {
    private func parse(_ json: String) -> PrActivity {
        let raw = try! JSONDecoder().decode(RawPrActivityForTest.self, from: Data(json.utf8))
        return parsePrActivity(raw)
    }

    func testParsesChecksCommentsAndReviews() {
        let a = parse("""
        {
          "state": "open",
          "statusCheckRollup": [{"status":"COMPLETED","conclusion":"FAILURE"}],
          "comments": [{"id":"c1","author":{"login":"octocat"},"body":"nit: rename"}],
          "reviews": [{"id":"r1","author":{"login":"hubber"},"body":"please fix","state":"changes_requested"}]
        }
        """)
        XCTAssertEqual(a.state, "OPEN")  // state is upper-cased on parse
        XCTAssertEqual(a.checks, .failing)
        XCTAssertEqual(a.comments, [PrComment(id: "c1", author: "octocat", body: "nit: rename")])
        // state is upper-cased on parse.
        XCTAssertEqual(a.reviews, [PrReview(id: "r1", author: "hubber", body: "please fix", state: "CHANGES_REQUESTED")])
    }

    func testDropsCommentsAndReviewsMissingAnId() {
        let a = parse("""
        {
          "comments": [{"author":{"login":"x"},"body":"no id"},{"id":"c2","body":"kept"}],
          "reviews": [{"author":{"login":"y"},"state":"COMMENTED"}]
        }
        """)
        XCTAssertEqual(a.comments.map(\.id), ["c2"])
        XCTAssertTrue(a.reviews.isEmpty)
    }

    func testHandlesMissingArraysAsEmpty() {
        let a = parse("{}")
        XCTAssertEqual(a.checks, .none)
        XCTAssertTrue(a.comments.isEmpty)
        XCTAssertTrue(a.reviews.isEmpty)
    }
}

// MARK: - classifyPrActivity

final class ClassifyPrActivityTests: XCTestCase {
    private func activity(state: String = "OPEN",
                          checks: PrChecks = .none,
                          comments: [PrComment] = [],
                          reviews: [PrReview] = []) -> PrActivity {
        PrActivity(state: state, checks: checks, comments: comments, reviews: reviews)
    }

    func testFirstPollOnlyBaselinesAndEmitsNoEvents() {
        let r = classifyPrActivity(
            prev: PrTrackSnapshot(),  // baselined: false
            activity: activity(checks: .failing,
                               comments: [PrComment(id: "c1", author: "a", body: "x")],
                               reviews: [PrReview(id: "r1", author: "a", body: "b", state: "CHANGES_REQUESTED")]))
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertTrue(r.snapshot.baselined)
        XCTAssertEqual(r.snapshot.seenCommentIds, ["c1"])
        XCTAssertEqual(r.snapshot.seenReviewIds, ["r1"])
        XCTAssertEqual(r.snapshot.checks, .failing)
    }

    func testNewCommentIsAutoFix() {
        let prev = PrTrackSnapshot(seenCommentIds: ["c1"], checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            checks: .passing,
            comments: [PrComment(id: "c1", author: "a", body: "old"),
                       PrComment(id: "c2", author: "octocat", body: "new nit")]))
        XCTAssertEqual(r.events.count, 1)
        guard case .autoFix(let reason) = r.events[0] else { return XCTFail("expected autoFix") }
        XCTAssertTrue(reason.contains("1 new comment"))
        XCTAssertTrue(reason.contains("@octocat"))
    }

    func testChangesRequestedReviewIsNeedsDecision() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            checks: .passing,
            reviews: [PrReview(id: "r1", author: "hubber", body: "no", state: "CHANGES_REQUESTED")]))
        XCTAssertEqual(r.events.count, 1)
        guard case .needsDecision(let reason) = r.events[0] else { return XCTFail("expected needsDecision") }
        XCTAssertTrue(reason.contains("@hubber"))
    }

    func testCommentedReviewWithBodyIsAutoFixButEmptyBodyIsIgnored() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let withBody = classifyPrActivity(prev: prev, activity: activity(
            reviews: [PrReview(id: "r1", author: "a", body: "tweak this", state: "COMMENTED")]))
        XCTAssertEqual(withBody.events.count, 1)
        guard case .autoFix = withBody.events[0] else { return XCTFail("expected autoFix") }

        let emptyBody = classifyPrActivity(prev: prev, activity: activity(
            reviews: [PrReview(id: "r2", author: "a", body: "   ", state: "COMMENTED")]))
        XCTAssertTrue(emptyBody.events.isEmpty)
    }

    func testApprovedReviewEmitsNothing() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            reviews: [PrReview(id: "r1", author: "a", body: "LGTM", state: "APPROVED")]))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testCiTransitionToFailingIsAutoFix() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(checks: .failing))
        XCTAssertEqual(r.events.count, 1)
        guard case .autoFix(let reason) = r.events[0] else { return XCTFail("expected autoFix") }
        XCTAssertTrue(reason.contains("CI"))
    }

    func testCiStayingFailingDoesNotReFire() {
        let prev = PrTrackSnapshot(checks: .failing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(checks: .failing))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testMixedDecisionAndAutoFixInOnePoll() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            checks: .failing,
            comments: [PrComment(id: "c1", author: "a", body: "nit")],
            reviews: [PrReview(id: "r1", author: "b", body: "no", state: "CHANGES_REQUESTED")]))
        let autoFixes = r.events.filter { if case .autoFix = $0 { return true }; return false }
        let decisions = r.events.filter { if case .needsDecision = $0 { return true }; return false }
        XCTAssertEqual(autoFixes.count, 2)  // new comment + CI failing
        XCTAssertEqual(decisions.count, 1)  // changes requested
    }

    func testMergedOrClosedEmitsSingleClosedEventIgnoringOtherActivity() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let merged = classifyPrActivity(prev: prev, activity: activity(
            state: "MERGED", checks: .failing,
            comments: [PrComment(id: "c1", author: "a", body: "nit")]))
        XCTAssertEqual(merged.events, [.closed("PR was merged — stopped tracking")])

        let closed = classifyPrActivity(prev: prev, activity: activity(state: "CLOSED"))
        XCTAssertEqual(closed.events, [.closed("PR was closed — stopped tracking")])
    }

    func testMergedEmitsClosedEvenBeforeBaseline() {
        let r = classifyPrActivity(prev: PrTrackSnapshot(), activity: activity(state: "MERGED"))
        XCTAssertEqual(r.events, [.closed("PR was merged — stopped tracking")])
    }

    func testCodexOutOfCapacityCommentIsAutoFixToReviewAndQueue() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            checks: .passing,
            comments: [PrComment(id: "c1", author: "codex",
                                 body: "You have reached your Codex usage limits for code reviews.")]))
        let autoFixReasons = r.events.compactMap { if case .autoFix(let s) = $0 { return s }; return nil }
        XCTAssertTrue(autoFixReasons.contains { $0.contains("Codex is out of review capacity") })
        XCTAssertTrue(autoFixReasons.contains { $0.contains("@mergifyio queue") })
    }

    func testCodexLimitNoticeInReviewBodyAlsoTriggers() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            reviews: [PrReview(id: "r1", author: "codex",
                               body: "reached your Codex usage limits for code reviews", state: "COMMENTED")]))
        let autoFixReasons = r.events.compactMap { if case .autoFix(let s) = $0 { return s }; return nil }
        XCTAssertTrue(autoFixReasons.contains { $0.contains("Codex is out of review capacity") })
    }
}

// MARK: - deriveTrackState

final class DeriveTrackStateTests: XCTestCase {
    func testOpenDecisionAlwaysWins() {
        XCTAssertEqual(deriveTrackState(checks: .passing, hasOpenDecision: true), .needsDecision)
        XCTAssertEqual(deriveTrackState(checks: .failing, hasOpenDecision: true), .needsDecision)
    }
    func testFailingOrPendingIsFixing() {
        XCTAssertEqual(deriveTrackState(checks: .failing, hasOpenDecision: false), .fixing)
        XCTAssertEqual(deriveTrackState(checks: .pending, hasOpenDecision: false), .fixing)
    }
    func testPassingOrNoneIsWatching() {
        XCTAssertEqual(deriveTrackState(checks: .passing, hasOpenDecision: false), .watching)
        XCTAssertEqual(deriveTrackState(checks: .none, hasOpenDecision: false), .watching)
    }
}

// MARK: - prompt builders

final class TrackPromptTests: XCTestCase {
    func testSeedPromptCarriesPrContextAndContract() {
        let p = trackSeedPrompt(number: 42, title: "Fix login", branch: "fix-login",
                                url: "https://github.com/o/r/pull/42")
        XCTAssertTrue(p.contains("#42"))
        XCTAssertTrue(p.contains("Fix login"))
        XCTAssertTrue(p.contains("fix-login"))
        XCTAssertTrue(p.contains("https://github.com/o/r/pull/42"))
        XCTAssertTrue(p.contains("STOP"))  // the escalate contract
    }

    func testAutoFixPromptJoinsReasonsAndNamesBranch() {
        let p = autoFixPrompt(number: 7, branch: "feat", reasons: ["CI checks are failing", "1 new comment"])
        XCTAssertTrue(p.contains("#7"))
        XCTAssertTrue(p.contains("CI checks are failing; 1 new comment"))
        XCTAssertTrue(p.contains("`feat`"))
    }

    func testTrackedPrKeyAndDerivedState() {
        var t = TrackedPr(number: 3, title: "t", branch: "b", url: "u", cwd: "/repo", sessionId: "s")
        XCTAssertEqual(t.id, "/repo#3")
        XCTAssertEqual(t.state, .watching)  // .none checks, no decisions
        t.snapshot.checks = .failing
        XCTAssertEqual(t.state, .fixing)
        t.notifications = [TrackNotification(id: "n", prNumber: 3, message: "m", createdAt: 0)]
        XCTAssertEqual(t.state, .needsDecision)
    }
}
