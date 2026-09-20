import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the half of the tracked-PR logic that still needs the Swift
/// core's own pollers (juancode-idza): the `gh pr view --json` parser, the pure
/// activity classifier, and the seed prompt that names the agent's worktree. The
/// DTOs, the derived badge state and the GitHub view's prompt builders moved to
/// `Tests/JuancodeCoreTests/TrackedPrTests.swift` with the types. No `gh` spawn.

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

    func testIgnoresSelfAuthoredCommentsAndReviews() {
        // The tracking agent posts as `viewerLogin`; its own comments/reviews must not
        // be treated as new activity (that echo-fires the poller), but must still land
        // in the baseline so they never re-surface. Match is case-insensitive.
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            checks: .passing,
            comments: [PrComment(id: "c1", author: "JuanOne", body: "posted my review"),
                       PrComment(id: "c2", author: "reviewer", body: "actual feedback")],
            reviews: [PrReview(id: "r1", author: "juanone", body: "self review", state: "COMMENTED")]),
            viewerLogin: "juanone")
        // Only the outside reviewer's comment fires.
        XCTAssertEqual(r.events.count, 1)
        guard case .autoFix(let reason) = r.events[0] else { return XCTFail("expected autoFix") }
        XCTAssertTrue(reason.contains("1 new comment"))
        XCTAssertTrue(reason.contains("@reviewer"))
        XCTAssertFalse(reason.contains("@JuanOne"))
        // Self-authored items are still baselined.
        XCTAssertEqual(r.snapshot.seenCommentIds, ["c1", "c2"])
        XCTAssertEqual(r.snapshot.seenReviewIds, ["r1"])
    }

    func testNoViewerLoginFiltersNothing() {
        let prev = PrTrackSnapshot(checks: .passing, baselined: true)
        let r = classifyPrActivity(prev: prev, activity: activity(
            comments: [PrComment(id: "c1", author: "juanone", body: "hi")]))
        XCTAssertEqual(r.events.count, 1)  // no viewer login ⇒ no self-filter
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

// MARK: - trackSeedPrompt

final class TrackSeedPromptTests: XCTestCase {
    func testSeedPromptCarriesPrContextAndContract() {
        let p = trackSeedPrompt(number: 42, title: "Fix login", branch: "fix-login",
                                url: "https://github.com/o/r/pull/42")
        XCTAssertTrue(p.contains("#42"))
        XCTAssertTrue(p.contains("Fix login"))
        XCTAssertTrue(p.contains("fix-login"))
        XCTAssertTrue(p.contains("https://github.com/o/r/pull/42"))
        XCTAssertTrue(p.contains("STOP"))  // the escalate contract
    }
}
