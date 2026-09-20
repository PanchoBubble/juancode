import XCTest
@testable import JuancodeCore

/// Unit tests for the tracked-PR types that outlive the Swift core (juancode-idza):
/// the derived badge state, the prompt builders the GitHub view uses, and the
/// level-triggered CI recovery check. The classifier and the seed prompt stayed in
/// `Tests/JuancodeServicesTests/PrTrackClassifierTests.swift` with their argument
/// types (`PrActivity`, `BranchWorktree`).

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

// MARK: - level-triggered CI recovery

/// `stalledCiFixReason` (juancode-kmwa): the classifier is edge-triggered, so red
/// CI with no live agent has to be recovered on a level check instead.
final class StalledCiRecoveryTests: XCTestCase {

    func testStalledCiFiresWhenRedAndSessionGone() throws {
        let r = stalledCiFixReason(checks: .failing, sessionLive: false, hasPendingFixes: false)
        XCTAssertNotNil(r)
        XCTAssertTrue(try XCTUnwrap(r).contains("still failing"))
    }

    func testStalledCiSilentWhenSessionIsLive() {
        // An agent already working the PR must not be re-prompted every poll.
        XCTAssertNil(stalledCiFixReason(checks: .failing, sessionLive: true, hasPendingFixes: false))
    }

    func testStalledCiSilentWhenThePollAlreadyProducedFixWork() {
        // That prompt revives the session by itself; two reasons would double-poke.
        XCTAssertNil(stalledCiFixReason(checks: .failing, sessionLive: false, hasPendingFixes: true))
    }

    func testStalledCiSilentWhenCiIsNotRed() {
        for checks in [PrChecks.passing, .pending, .none] {
            XCTAssertNil(stalledCiFixReason(checks: checks, sessionLive: false, hasPendingFixes: false),
                         "\(checks) should not trigger recovery")
        }
    }
}

// MARK: - commentTaskPrompt

/// The prompt a review comment is handed to an agent as. It lives beside the rest of
/// the tracked-PR prompt builders because that is where `commentTaskPrompt` lives; it
/// only ever sat in the conversation tests because the conversation was what produced
/// the comment.
final class CommentTaskPromptTests: XCTestCase {
    func testCommentTaskPromptCarriesTheComment() {
        let prompt = commentTaskPrompt(
            number: 42, path: "Sources/App/Main.swift", line: 17,
            author: "bob", body: "This can crash on nil",
            url: "https://github.com/o/r/pull/42#discussion_r222")
        XCTAssertTrue(prompt.contains("#42"))
        XCTAssertTrue(prompt.contains("Sources/App/Main.swift:17"))
        XCTAssertTrue(prompt.contains("@bob"))
        XCTAssertTrue(prompt.contains("This can crash on nil"))
        XCTAssertTrue(prompt.contains("https://github.com/o/r/pull/42#discussion_r222"))
        // Must instruct the agent to close the loop on the thread.
        XCTAssertTrue(prompt.lowercased().contains("reply"))
        XCTAssertTrue(prompt.contains("`gh`"))
    }

    func testCommentTaskPromptCarriesTheDiffHunk() {
        let prompt = commentTaskPrompt(
            number: 42, path: "Sources/App/Main.swift", line: 17,
            author: "bob", body: "This can crash on nil", url: "u",
            diffHunk: "@@ -15,3 +15,4 @@\n     let a = 1\n-    return a\n+    return unwrap(a)")
        XCTAssertTrue(prompt.contains("```diff"))
        XCTAssertTrue(prompt.contains("+    return unwrap(a)"))
        // The comment body still leads; the hunk is context beneath it.
        guard let bodyAt = prompt.range(of: "This can crash on nil"),
              let hunkAt = prompt.range(of: "```diff") else {
            return XCTFail("prompt missing the body or the hunk")
        }
        XCTAssertTrue(bodyAt.lowerBound < hunkAt.lowerBound)
    }

    func testCommentTaskPromptOmitsEmptyDiffHunk() {
        for hunk in [nil, "", "   \n  "] as [String?] {
            let prompt = commentTaskPrompt(
                number: 42, path: "a.swift", line: 1, author: "bob", body: "note",
                url: "u", diffHunk: hunk)
            XCTAssertFalse(prompt.contains("```diff"))
            XCTAssertFalse(prompt.contains("The code it was left on"))
        }
    }

    func testCommentTaskPromptWithoutPathOmitsLocation() {
        let prompt = commentTaskPrompt(
            number: 7, path: nil, line: nil,
            author: "", body: "Top-level note",
            url: "https://github.com/o/r/pull/7#issuecomment-1")
        XCTAssertFalse(prompt.contains(" on `"))
        // Author fallback matches the tracker's "a reviewer" voice.
        XCTAssertTrue(prompt.contains("a reviewer"))
        XCTAssertTrue(prompt.contains("#7"))
    }

    func testCommentTaskPromptWithPathButNoLine() {
        let prompt = commentTaskPrompt(
            number: 7, path: "README.md", line: nil,
            author: "alice", body: "typo", url: "u")
        XCTAssertTrue(prompt.contains("`README.md`"))
        XCTAssertFalse(prompt.contains("README.md:"))
    }
}
