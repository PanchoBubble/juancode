import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Unit tests for the tracked-issue engine (juancode-z4v): the GraphQL parser, the
/// pure classifier that diffs issue activity into next-step vs needs-decision events,
/// the derived badge state, the token resolver, and the prompt builders. No network.

// MARK: - parseIssueActivity

final class ParseIssueActivityTests: XCTestCase {
    private func parse(_ json: String) -> IssueActivity? {
        let raw = try! JSONDecoder().decode(RawIssueForTest.self, from: Data(json.utf8))
        return parseIssueActivity(raw)
    }

    func testParsesTheRealEnvelopeShape() {
        // The exact shape Linear's GraphQL API returns.
        let a = parse("""
        {"data":{"issue":{
          "identifier":"ENG-42","title":"Fix login","url":"https://linear.app/o/issue/ENG-42",
          "state":{"name":"Ongoing","type":"started"},
          "assignee":{"displayName":"Juan"},
          "comments":{"nodes":[
            {"id":"c1","body":"please tweak","user":{"displayName":"octo"}},
            {"id":"c2","body":"bot note"}
          ]}
        }}}
        """)
        XCTAssertEqual(a?.identifier, "ENG-42")
        XCTAssertEqual(a?.title, "Fix login")
        XCTAssertEqual(a?.stateName, "Ongoing")
        XCTAssertEqual(a?.stateType, "started")
        XCTAssertEqual(a?.assignee, "Juan")
        XCTAssertEqual(a?.comments, [
            IssueComment(id: "c1", author: "octo", body: "please tweak"),
            IssueComment(id: "c2", author: "", body: "bot note"),  // missing user → empty author
        ])
    }

    func testNilWhenIssueMissing() {
        XCTAssertNil(parse(#"{"data":{"issue":null}}"#))
        XCTAssertNil(parse(#"{"data":{}}"#))
        XCTAssertNil(parse(#"{}"#))
    }

    func testDropsCommentsMissingAnId() {
        let a = parse("""
        {"data":{"issue":{"identifier":"E-1","state":{"name":"X","type":"backlog"},
          "comments":{"nodes":[{"body":"no id"},{"id":"k","body":"kept"}]}}}}
        """)
        XCTAssertEqual(a?.comments.map(\.id), ["k"])
    }
}

// MARK: - classifyIssueActivity

final class ClassifyIssueActivityTests: XCTestCase {
    private func activity(stateName: String = "Backlog", stateType: String = "backlog",
                          comments: [IssueComment] = []) -> IssueActivity {
        IssueActivity(identifier: "ENG-1", title: "t", url: "u", stateName: stateName,
                      stateType: stateType, assignee: "", comments: comments)
    }

    func testFirstPollOnlyBaselinesAndEmitsNoEvents() {
        let r = classifyIssueActivity(
            prev: IssueTrackSnapshot(),  // baselined: false
            activity: activity(stateName: "Done", stateType: "completed",
                               comments: [IssueComment(id: "c1", author: "a", body: "x")]))
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertTrue(r.snapshot.baselined)
        XCTAssertEqual(r.snapshot.seenCommentIds, ["c1"])
        XCTAssertEqual(r.snapshot.stateType, "completed")
    }

    func testNewCommentIsNextStep() {
        let prev = IssueTrackSnapshot(seenCommentIds: ["c1"], stateType: "started", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(
            stateName: "Ongoing", stateType: "started",
            comments: [IssueComment(id: "c1", author: "a", body: "old"),
                       IssueComment(id: "c2", author: "octo", body: "new note")]))
        XCTAssertEqual(r.events.count, 1)
        guard case .autoFix(let reason) = r.events[0] else { return XCTFail("expected autoFix") }
        XCTAssertTrue(reason.contains("1 new comment"))
        XCTAssertTrue(reason.contains("@octo"))
    }

    func testMoveToCompletedIsNeedsDecision() {
        let prev = IssueTrackSnapshot(stateType: "started", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(stateName: "Done", stateType: "completed"))
        XCTAssertEqual(r.events.count, 1)
        guard case .needsDecision(let reason) = r.events[0] else { return XCTFail("expected needsDecision") }
        XCTAssertTrue(reason.contains("Done"))
    }

    func testMoveToCanceledIsNeedsDecision() {
        let prev = IssueTrackSnapshot(stateType: "started", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(stateName: "Canceled", stateType: "canceled"))
        XCTAssertEqual(r.events.count, 1)
        guard case .needsDecision = r.events[0] else { return XCTFail("expected needsDecision") }
    }

    func testNonTerminalStateMoveIsInformational() {
        let prev = IssueTrackSnapshot(stateType: "backlog", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(stateName: "Ongoing", stateType: "started"))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testSameStateDoesNotReFire() {
        let prev = IssueTrackSnapshot(stateType: "completed", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(stateName: "Done", stateType: "completed"))
        XCTAssertTrue(r.events.isEmpty)
    }

    func testMixedNewCommentAndCancelInOnePoll() {
        let prev = IssueTrackSnapshot(stateType: "started", baselined: true)
        let r = classifyIssueActivity(prev: prev, activity: activity(
            stateName: "Canceled", stateType: "canceled",
            comments: [IssueComment(id: "c1", author: "a", body: "fyi")]))
        let next = r.events.filter { if case .autoFix = $0 { return true }; return false }
        let decisions = r.events.filter { if case .needsDecision = $0 { return true }; return false }
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(decisions.count, 1)
    }
}

// MARK: - deriveIssueTrackState

final class DeriveIssueTrackStateTests: XCTestCase {
    func testOpenDecisionAlwaysWins() {
        XCTAssertEqual(deriveIssueTrackState(stateType: "started", hasOpenDecision: true), .needsDecision)
        XCTAssertEqual(deriveIssueTrackState(stateType: "completed", hasOpenDecision: true), .needsDecision)
    }
    func testTerminalIsDone() {
        XCTAssertEqual(deriveIssueTrackState(stateType: "completed", hasOpenDecision: false), .done)
        XCTAssertEqual(deriveIssueTrackState(stateType: "canceled", hasOpenDecision: false), .done)
    }
    func testStartedIsActiveElseWatching() {
        XCTAssertEqual(deriveIssueTrackState(stateType: "started", hasOpenDecision: false), .active)
        XCTAssertEqual(deriveIssueTrackState(stateType: "backlog", hasOpenDecision: false), .watching)
        XCTAssertEqual(deriveIssueTrackState(stateType: "", hasOpenDecision: false), .watching)
    }
}

// MARK: - token resolver

final class LinearTokenTests: XCTestCase {
    func testPrefersJuancodeOverrideThenLinearKey() {
        XCTAssertEqual(linearToken(["JUANCODE_LINEAR_TOKEN": "a", "LINEAR_API_KEY": "b"]), "a")
        XCTAssertEqual(linearToken(["LINEAR_API_KEY": "b"]), "b")
        XCTAssertNil(linearToken([:]))
        XCTAssertNil(linearToken(["LINEAR_API_KEY": "   "]))  // blank is treated as unset
    }
}

// MARK: - prompt builders

final class IssuePromptTests: XCTestCase {
    func testSeedPromptCarriesIssueContextAndContract() {
        let p = trackIssueSeedPrompt(identifier: "ENG-9", title: "Fix login",
                                     url: "https://linear.app/o/issue/ENG-9")
        XCTAssertTrue(p.contains("ENG-9"))
        XCTAssertTrue(p.contains("Fix login"))
        XCTAssertTrue(p.contains("https://linear.app/o/issue/ENG-9"))
        XCTAssertTrue(p.contains("STOP"))
    }

    func testActivityPromptJoinsReasons() {
        let p = issueActivityPrompt(identifier: "ENG-3", reasons: ["1 new comment", "issue was canceled"])
        XCTAssertTrue(p.contains("ENG-3"))
        XCTAssertTrue(p.contains("1 new comment; issue was canceled"))
    }

    func testTrackedIssueKeyAndDerivedState() {
        var t = TrackedIssue(identifier: "ENG-3", title: "t", url: "u", cwd: "/repo", sessionId: "s")
        XCTAssertEqual(t.id, "/repo#ENG-3")
        XCTAssertEqual(t.state, .watching)  // empty stateType, no decisions
        t.snapshot.stateType = "started"
        XCTAssertEqual(t.state, .active)
        t.notifications = [IssueTrackNotification(id: "n", issueIdentifier: "ENG-3", message: "m", createdAt: 0)]
        XCTAssertEqual(t.state, .needsDecision)
    }
}
