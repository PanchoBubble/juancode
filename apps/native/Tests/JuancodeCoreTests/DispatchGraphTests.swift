import XCTest
@testable import JuancodeCore

/// Tests for the dispatch-chain graph (juancode-wn64): the linkage rules that
/// turn state the app already holds into nodes and edges, and the layered layout.
final class DispatchGraphTests: XCTestCase {
    private let project = "/repo"

    private func issue(_ id: String, title: String = "t", status: String = "open",
                       parent: String? = nil, priority: Int = 2,
                       ready: Bool = true, blocked: Bool = false) -> BeadsIssue {
        BeadsIssue(id: id, title: title, status: status, priority: priority, issueType: "task",
                   parent: parent, dependencyCount: 0, dependentCount: 0,
                   ready: ready, blocked: blocked)
    }

    private func meta(_ id: String, cwd: String? = nil, title: String = "",
                      worktree: String? = nil, status: SessionStatus = .running,
                      updatedAt: Int = 1_000, dispatchId: String? = nil) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: cwd ?? project, title: title,
                    status: status, exitCode: nil, createdAt: updatedAt, updatedAt: updatedAt,
                    cliSessionId: nil, skipPermissions: true, worktreePath: worktree,
                    usage: nil, dispatchId: dispatchId)
    }

    // MARK: - the whole chain

    func testFullChainTicketToPr() {
        let input = DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-wn64"))],
            dispatches: [GraphDispatchInput(
                dispatchId: "d1", project: project,
                prompt: "Implement bd ticket juancode-wn64: graph view", provider: "claude",
                sessionId: "s1", outcome: "started", at: 5_000)],
            sessions: [GraphSessionInput(meta: meta("s1", worktree: "/wt/a"), activity: .busy,
                                         live: true)],
            worktrees: [Worktree(path: "/wt/a", branch: "juancode/a", head: nil, main: false)],
            prs: [GraphPrInput(cwd: project, number: 12, title: "graph view", branch: "juancode/a",
                               checks: .passing, tracked: true, sessionId: "s1")])

        let g = DispatchGraph.build(input)
        XCTAssertEqual(g.nodes.count, 5)
        XCTAssertEqual(Set(g.nodes.map(\.kind)), Set(GraphNodeKind.allCases))
        // One chain, and the columns are the enum order.
        XCTAssertEqual(g.chains.count, 1)
        for node in g.nodes { XCTAssertEqual(node.layer, node.kind.layer) }

        let ticket = DispatchGraph.ticketId(project: project, issue: "juancode-wn64")
        let dispatch = DispatchGraph.dispatchNodeId("d1")
        let session = DispatchGraph.sessionNodeId("s1")
        let worktree = DispatchGraph.worktreeNodeId("/wt/a")
        let pr = DispatchGraph.prNodeId(cwd: project, number: 12)
        for edge in [GraphEdge(from: ticket, to: dispatch), GraphEdge(from: dispatch, to: session),
                     GraphEdge(from: session, to: worktree), GraphEdge(from: worktree, to: pr)] {
            XCTAssertTrue(g.edges.contains(edge), "missing \(edge.id)")
        }
        // The busy session and the green PR carry their state through.
        XCTAssertEqual(g.node(session)?.state, .running)
        XCTAssertEqual(g.node(pr)?.state, .done)
        XCTAssertEqual(g.node(pr)?.badge, "CI green")
        XCTAssertEqual(g.node(session)?.jump, .session("s1"))
        XCTAssertEqual(g.node(pr)?.jump, .pr(cwd: project, number: 12))
        XCTAssertEqual(g.node(ticket)?.jump, .ticket(cwd: project, id: "juancode-wn64"))
    }

    func testSessionWithoutWorktreeEdgesStraightToPr() {
        let input = DispatchGraphInput(
            sessions: [GraphSessionInput(meta: meta("s1"), live: true)],
            prs: [GraphPrInput(cwd: project, number: 3, title: "fix", branch: "feature/x",
                               checks: .failing, tracked: true, sessionId: "s1")])
        let g = DispatchGraph.build(input)
        let session = DispatchGraph.sessionNodeId("s1")
        let pr = DispatchGraph.prNodeId(cwd: project, number: 3)
        XCTAssertTrue(g.edges.contains(GraphEdge(from: session, to: pr)))
        XCTAssertFalse(g.nodes.contains { $0.kind == .worktree })
        XCTAssertEqual(g.node(pr)?.state, .failed)
    }

    func testBranchInPlaceBecomesABranchNode() {
        let input = DispatchGraphInput(
            sessions: [GraphSessionInput(meta: meta("s1"), live: true, branch: "main")])
        let g = DispatchGraph.build(input)
        let branch = g.nodes.first { $0.kind == .worktree }
        XCTAssertEqual(branch?.label, "main")
        XCTAssertEqual(branch?.badge, "in place")
        XCTAssertEqual(branch?.jump, .session("s1"))
    }

    func testUntrackedPrOnTheSessionBranchStillLinks() {
        let input = DispatchGraphInput(
            sessions: [GraphSessionInput(meta: meta("s1", worktree: "/wt/a"), live: true)],
            worktrees: [Worktree(path: "/wt/a", branch: "juancode/a", head: nil, main: false)],
            prs: [GraphPrInput(cwd: project, number: 9, title: "open", branch: "juancode/a",
                               checks: .pending)])
        let g = DispatchGraph.build(input)
        XCTAssertTrue(g.edges.contains(GraphEdge(from: DispatchGraph.worktreeNodeId("/wt/a"),
                                                 to: DispatchGraph.prNodeId(cwd: project, number: 9))))
        XCTAssertEqual(g.node(DispatchGraph.prNodeId(cwd: project, number: 9))?.state, .running)
    }

    func testPrOnAnotherBranchIsNotLinked() {
        let input = DispatchGraphInput(
            sessions: [GraphSessionInput(meta: meta("s1", worktree: "/wt/a"), live: true)],
            worktrees: [Worktree(path: "/wt/a", branch: "juancode/a", head: nil, main: false)],
            prs: [GraphPrInput(cwd: project, number: 9, title: "other", branch: "juancode/b",
                               checks: .passing)])
        let g = DispatchGraph.build(input)
        XCTAssertFalse(g.nodes.contains { $0.kind == .pr })
    }

    func testTrackedPrWithNoSessionStillAppears() {
        let input = DispatchGraphInput(
            prs: [GraphPrInput(cwd: project, number: 4, title: "orphan", branch: "b",
                               checks: .failing, tracked: true, sessionId: "gone")])
        let g = DispatchGraph.build(input)
        XCTAssertEqual(g.nodes.map(\.kind), [.pr])
        XCTAssertEqual(g.chains.count, 1)
    }

    // MARK: - ticket linkage

    /// A dispatch prompt names siblings after the ticket it implements ("juancode-x
    /// is editing the same area tonight"); only the leading mention is the work.
    func testOnlyTheLeadingTicketMentionLinks() {
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-mine")),
                     GraphIssueInput(project: project, issue: issue("juancode-theirs"))],
            dispatches: [GraphDispatchInput(
                dispatchId: "d1", project: project,
                prompt: "Implement juancode-mine. LANE: juancode-theirs is in the same file.",
                provider: "claude", sessionId: nil, outcome: "queued", at: 1)]))
        XCTAssertEqual(g.nodes.filter { $0.kind == .ticket }.map(\.label), ["juancode-mine"])
    }

    func testMentionedIdsComeBackInTextOrder() {
        XCTAssertEqual(
            DispatchGraph.mentionedIds(in: "first b-two then a-one",
                                       known: ["a-one", "b-two"]),
            ["b-two", "a-one"])
    }

    func testOnlyKnownTicketIdsBecomeNodes() {
        let input = DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-wn64"))],
            dispatches: [GraphDispatchInput(
                dispatchId: "d1", project: project,
                prompt: "work juancode-wn64 and also juancode-nope, plus some hyphen-word",
                provider: "claude", sessionId: nil, outcome: "queued", at: 1)],
            sessions: [])
        let g = DispatchGraph.build(input)
        XCTAssertEqual(g.nodes.filter { $0.kind == .ticket }.map(\.label), ["juancode-wn64"])
    }

    func testLongerIdDoesNotMatchAsAPrefix() {
        XCTAssertEqual(DispatchGraph.mentionedIds(in: "see juancode-wn64 tonight",
                                                  known: ["juancode-wn6"]), [])
        XCTAssertEqual(DispatchGraph.mentionedIds(in: "see juancode-wn64 tonight",
                                                  known: ["juancode-wn64"]), ["juancode-wn64"])
    }

    func testMentionMatchIsCaseInsensitiveAndBoundaryAware() {
        XCTAssertEqual(DispatchGraph.mentionedIds(in: "Ticket JUANCODE-WN64.", known: ["juancode-wn64"]),
                       ["juancode-wn64"])
        XCTAssertEqual(DispatchGraph.mentionedIds(in: "xjuancode-wn64", known: ["juancode-wn64"]), [])
        XCTAssertEqual(DispatchGraph.mentionedIds(in: "", known: ["juancode-wn64"]), [])
    }

    func testSessionTitleAndBranchNameTicketWithoutADispatch() {
        let byTitle = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-abc"))],
            sessions: [GraphSessionInput(meta: meta("s1", title: "juancode-abc: do the thing"))]))
        XCTAssertTrue(byTitle.edges.contains(GraphEdge(
            from: DispatchGraph.ticketId(project: project, issue: "juancode-abc"),
            to: DispatchGraph.sessionNodeId("s1"))))

        let byBranch = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-abc"))],
            sessions: [GraphSessionInput(meta: meta("s2"), branch: "ticket/juancode-abc")]))
        XCTAssertTrue(byBranch.edges.contains(GraphEdge(
            from: DispatchGraph.ticketId(project: project, issue: "juancode-abc"),
            to: DispatchGraph.sessionNodeId("s2"))))
    }

    /// With a dispatch record, the ticket hangs off the dispatch — not the session
    /// as well; the chain reads left to right with no shortcut edge.
    func testTicketEdgeGoesToTheDispatchWhenThereIsOne() {
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-abc"))],
            dispatches: [GraphDispatchInput(dispatchId: "d1", project: project,
                                            prompt: "juancode-abc", provider: "claude",
                                            sessionId: "s1", outcome: "started", at: 2)],
            sessions: [GraphSessionInput(meta: meta("s1", title: "juancode-abc"))]))
        let ticket = DispatchGraph.ticketId(project: project, issue: "juancode-abc")
        XCTAssertTrue(g.edges.contains(GraphEdge(from: ticket, to: DispatchGraph.dispatchNodeId("d1"))))
        XCTAssertFalse(g.edges.contains(GraphEdge(from: ticket, to: DispatchGraph.sessionNodeId("s1"))))
    }

    func testParentTicketArrivesAsADependencyEdge() {
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("child", parent: "epic")),
                     GraphIssueInput(project: project, issue: issue("epic"))],
            dispatches: [GraphDispatchInput(dispatchId: "d1", project: project, prompt: "do child",
                                            provider: "claude", sessionId: nil, outcome: "queued",
                                            at: 1)])
        )
        let child = DispatchGraph.ticketId(project: project, issue: "child")
        let epic = DispatchGraph.ticketId(project: project, issue: "epic")
        XCTAssertNotNil(g.node(epic))
        XCTAssertTrue(g.edges.contains(GraphEdge(from: epic, to: child, kind: .dependency)))
        // Both tickets share the column, so the dependency edge is intra-layer.
        XCTAssertEqual(g.node(epic)?.layer, g.node(child)?.layer)
    }

    func testWorktreeSessionResolvesTicketsAgainstItsRepoProject() {
        // An isolated session's cwd is the worktree dir; its issues are cached under
        // the repo root, which `projectCwd` maps back to.
        let repo = "/x/repo"
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: repo, issue: issue("juancode-abc"))],
            sessions: [GraphSessionInput(meta: meta("s1", cwd: "/x/repo-worktrees/aa",
                                                    title: "juancode-abc"))]))
        XCTAssertEqual(g.nodes.first { $0.kind == .ticket }?.project, repo)
    }

    // MARK: - dispatch outcomes

    func testRejectedAndQueuedDispatchesCarryTheirState() {
        let g = DispatchGraph.build(DispatchGraphInput(dispatches: [
            GraphDispatchInput(dispatchId: "d1", project: project, prompt: "a", provider: "claude",
                               sessionId: nil, outcome: "rejected", at: 1),
            GraphDispatchInput(dispatchId: "d2", project: project, prompt: "b", provider: "codex",
                               sessionId: nil, outcome: "queued", at: 2)]))
        XCTAssertEqual(g.node(DispatchGraph.dispatchNodeId("d1"))?.state, .failed)
        XCTAssertEqual(g.node(DispatchGraph.dispatchNodeId("d2"))?.state, .waiting)
        XCTAssertEqual(g.node(DispatchGraph.dispatchNodeId("d2"))?.label, "codex")
    }

    func testDispatchWhoseSessionIsGoneStillShowsWithoutADanglingEdge() {
        let g = DispatchGraph.build(DispatchGraphInput(dispatches: [
            GraphDispatchInput(dispatchId: "d1", project: project, prompt: "a", provider: "claude",
                               sessionId: "pruned", outcome: "started", at: 1)]))
        XCTAssertEqual(g.nodes.map(\.kind), [.dispatch])
        XCTAssertTrue(g.edges.isEmpty)
    }

    // MARK: - session state

    func testSessionStateMapsActivityAndExit() {
        let g = DispatchGraph.build(DispatchGraphInput(sessions: [
            GraphSessionInput(meta: meta("busy"), activity: .busy, live: true),
            GraphSessionInput(meta: meta("waiting"), activity: .waitingInput, live: true),
            GraphSessionInput(meta: meta("idle"), activity: .idle, live: true),
            GraphSessionInput(meta: meta("exited", status: .exited))]))
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("busy"))?.state, .running)
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("waiting"))?.state, .waiting)
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("waiting"))?.badge, "needs input")
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("idle"))?.state, .idle)
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("exited"))?.state, .done)
    }

    func testEditorSessionsAreNotInTheGraph() {
        var editor = meta("e1")
        editor.kind = .editor
        let g = DispatchGraph.build(DispatchGraphInput(
            sessions: [GraphSessionInput(meta: editor, live: true)]))
        XCTAssertTrue(g.isEmpty)
    }

    func testBlockedAndClosedTicketsCarryTheirState() {
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("blocked", blocked: true)),
                     GraphIssueInput(project: project, issue: issue("closed", status: "closed"))],
            dispatches: [GraphDispatchInput(dispatchId: "d1", project: project,
                                            prompt: "work blocked", provider: "claude",
                                            sessionId: nil, outcome: "queued", at: 1),
                         GraphDispatchInput(dispatchId: "d2", project: project,
                                            prompt: "work closed", provider: "claude",
                                            sessionId: nil, outcome: "queued", at: 2)]))
        XCTAssertEqual(g.node(DispatchGraph.ticketId(project: project, issue: "blocked"))?.state, .blocked)
        XCTAssertEqual(g.node(DispatchGraph.ticketId(project: project, issue: "closed"))?.state, .done)
    }

    // MARK: - layout

    func testChainsStackWithoutOverlappingRows() {
        let g = DispatchGraph.build(DispatchGraphInput(sessions: [
            GraphSessionInput(meta: meta("old", worktree: "/wt/old", updatedAt: 10), live: true),
            GraphSessionInput(meta: meta("new", worktree: "/wt/new", updatedAt: 99), live: true)],
            worktrees: [Worktree(path: "/wt/old", branch: "old", head: nil, main: false),
                        Worktree(path: "/wt/new", branch: "new", head: nil, main: false)]))
        XCTAssertEqual(g.chains.count, 2)
        XCTAssertEqual(g.rowCount, 2)
        // Freshest chain first.
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("new"))?.row, 0)
        XCTAssertEqual(g.node(DispatchGraph.sessionNodeId("old"))?.row, 1)
        // A chain's own nodes share its row.
        XCTAssertEqual(g.node(DispatchGraph.worktreeNodeId("/wt/new"))?.row, 0)
        XCTAssertEqual(g.node(DispatchGraph.worktreeNodeId("/wt/old"))?.row, 1)
    }

    func testTwoSessionsOnOneTicketTakeSeparateRowsInTheSameChain() {
        let g = DispatchGraph.build(DispatchGraphInput(
            issues: [GraphIssueInput(project: project, issue: issue("juancode-abc"))],
            sessions: [GraphSessionInput(meta: meta("s1", title: "juancode-abc one")),
                       GraphSessionInput(meta: meta("s2", title: "juancode-abc two"))]))
        XCTAssertEqual(g.chains.count, 1)
        let rows = g.nodes.filter { $0.kind == .session }.map(\.row).sorted()
        XCTAssertEqual(rows, [0, 1])
        XCTAssertEqual(g.node(DispatchGraph.ticketId(project: project, issue: "juancode-abc"))?.row, 0)
        XCTAssertEqual(g.rowCount, 2)
    }

    func testLayoutDropsEdgesToNodesThatWereNotBuilt() {
        let node = GraphNode(id: "a", kind: .session, label: "a", detail: "", state: .idle,
                             project: project)
        let g = DispatchGraph.layout(nodes: [node], edges: [GraphEdge(from: "a", to: "ghost")])
        XCTAssertTrue(g.edges.isEmpty)
        XCTAssertEqual(g.nodes.count, 1)
    }

    func testEmptyInputIsAnEmptyGraph() {
        let g = DispatchGraph.build(DispatchGraphInput())
        XCTAssertTrue(g.isEmpty)
        XCTAssertEqual(g.rowCount, 0)
        XCTAssertEqual(g.layerCount, GraphNodeKind.allCases.count)
    }
}
