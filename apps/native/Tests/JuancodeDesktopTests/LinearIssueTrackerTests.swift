import XCTest
import JuancodeCore
@testable import JuancodeDesktop

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

// MARK: - parseAssignedIssues

final class ParseAssignedIssuesTests: XCTestCase {
    private func parse(_ json: String) -> [IssueSummary] {
        let raw = try! JSONDecoder().decode(RawAssignedForTest.self, from: Data(json.utf8))
        return parseAssignedIssues(raw)
    }

    func testParsesViewerAssignedIssues() {
        let issues = parse("""
        {"data":{"viewer":{"assignedIssues":{"nodes":[
          {"identifier":"ENG-1","title":"Fix login","url":"https://linear.app/o/issue/ENG-1",
           "state":{"name":"Ongoing","type":"started"}},
          {"identifier":"ENG-2","title":"Triage","url":"u2","state":{"name":"Triage","type":"triage"}}
        ]}}}}
        """)
        XCTAssertEqual(issues.map(\.identifier), ["ENG-1", "ENG-2"])
        XCTAssertEqual(issues.first?.title, "Fix login")
        XCTAssertEqual(issues.first?.stateName, "Ongoing")
        XCTAssertEqual(issues.first?.stateType, "started")
    }

    func testDropsTerminalAndIdlessIssues() {
        let issues = parse("""
        {"data":{"viewer":{"assignedIssues":{"nodes":[
          {"identifier":"ENG-1","state":{"name":"Done","type":"completed"}},
          {"identifier":"ENG-2","state":{"name":"Canceled","type":"canceled"}},
          {"title":"no id","state":{"name":"Ongoing","type":"started"}},
          {"identifier":"ENG-3","state":{"name":"Backlog","type":"backlog"}}
        ]}}}}
        """)
        XCTAssertEqual(issues.map(\.identifier), ["ENG-3"])  // terminal + id-less dropped
    }

    func testEmptyWhenViewerMissing() {
        XCTAssertEqual(parse(#"{"data":{"viewer":null}}"#), [])
        XCTAssertEqual(parse(#"{"data":{}}"#), [])
        XCTAssertEqual(parse(#"{}"#), [])
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

// MARK: - offline escalation

/// `appendingAgentOfflineNotice`: a tracked issue whose agent session is gone (closed
/// from the sidebar, or unresumable) must say so once. The poll already advanced the
/// baseline past that activity, so a silently dropped prompt is work lost for good.
final class IssueAgentOfflineNoticeTests: XCTestCase {
    private func notice(_ message: String) -> IssueTrackNotification {
        IssueTrackNotification(id: "n0", issueIdentifier: "ENG-1", message: message, createdAt: 1)
    }

    func testAddsTheEscalationWhenNoneIsOutstanding() {
        let out = appendingAgentOfflineNotice([], identifier: "ENG-1", id: "n1", now: 42)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "n1")
        XCTAssertEqual(out[0].issueIdentifier, "ENG-1")
        XCTAssertEqual(out[0].createdAt, 42)
        XCTAssertEqual(out[0].message, issueAgentOfflineMessage)
    }

    func testDoesNotRepeatItselfOnEveryPoll() {
        let first = appendingAgentOfflineNotice([], identifier: "ENG-1", id: "n1", now: 1)
        let second = appendingAgentOfflineNotice(first, identifier: "ENG-1", id: "n2", now: 2)
        XCTAssertEqual(second, first)
    }

    func testKeepsUnrelatedDecisionsAndAppendsAfterThem() {
        let existing = [notice("issue was canceled (Canceled)")]
        let out = appendingAgentOfflineNotice(existing, identifier: "ENG-1", id: "n1", now: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], existing[0])
        XCTAssertEqual(out[1].message, issueAgentOfflineMessage)
    }

    func testAnEscalatedIssueReadsAsNeedsDecision() {
        var t = TrackedIssue(identifier: "ENG-1", title: "t", url: "u", cwd: "/repo", sessionId: "s")
        t.snapshot.stateType = "started"
        t.notifications = appendingAgentOfflineNotice(
            t.notifications, identifier: t.identifier, id: "n1", now: 1)
        XCTAssertEqual(t.state, .needsDecision)
    }
}
