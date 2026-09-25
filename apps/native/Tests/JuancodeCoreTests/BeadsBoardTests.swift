import Testing
@testable import JuancodeCore

/// The Beads view's board: which column an issue lands in, the filters over it,
/// and the summary counts.
@Suite struct BeadsBoardTests {
    private func issue(_ id: String, status: String = "open", priority: Int = 2, type: String = "task",
                       ready: Bool = false, blocked: Bool = false) -> BeadsIssue {
        BeadsIssue(id: id, title: "title of \(id)", status: status, priority: priority, issueType: type,
                   parent: nil, dependencyCount: 0, dependentCount: 0, ready: ready, blocked: blocked)
    }

    @Test func anOpenIssueIsBlockedOnlyWhenBdSaysSo() {
        #expect(BeadsColumn.of(issue("a", ready: true)) == .todo)
        #expect(BeadsColumn.of(issue("b", blocked: true)) == .blocked)
        #expect(BeadsColumn.of(issue("c", status: "in_progress")) == .inProgress)
        #expect(BeadsColumn.of(issue("d", status: "in_review")) == .inReview)
        #expect(BeadsColumn.of(issue("e", status: "closed")) == .done)
        #expect(BeadsColumn.of(issue("f", status: "deferred")) == .other("deferred"))
    }

    @Test func fixedColumnsAlwaysShowAndUnknownStatusesGetTheirOwn() {
        let cols = BeadsBoard.columns(open: [issue("a", status: "hooked"), issue("b", status: "deferred")],
                                      closed: [])
        #expect(cols.map(\.column) == [.todo, .blocked, .inProgress, .inReview,
                                       .other("deferred"), .other("hooked"), .done])
    }

    @Test func columnsSortByPriorityAndDoneKeepsBdsOrder() {
        let cols = BeadsBoard.columns(
            open: [issue("z", priority: 3), issue("y", priority: 0), issue("x", priority: 3)],
            closed: [issue("new", status: "closed"), issue("old", status: "closed")])
        #expect(cols[0].issues.map(\.id) == ["y", "x", "z"])
        #expect(cols.last?.issues.map(\.id) == ["new", "old"])
    }

    @Test func filterNarrowsEveryColumnIncludingDone() {
        let filter = BeadsFilter(priorities: [1], types: ["bug"])
        let cols = BeadsBoard.columns(
            open: [issue("a", priority: 1, type: "bug"), issue("b", priority: 1), issue("c", type: "bug")],
            closed: [issue("d", status: "closed", priority: 1, type: "bug"), issue("e", status: "closed")],
            filter: filter)
        #expect(cols[0].issues.map(\.id) == ["a"])
        #expect(cols.last?.issues.map(\.id) == ["d"])
    }

    @Test func queryMatchesIdOrTitle() {
        #expect(BeadsFilter(query: "AB-1").matches(issue("ab-12")))
        #expect(BeadsFilter(query: "title of x").matches(issue("x")))
        #expect(!BeadsFilter(query: "nope").matches(issue("x")))
        #expect(BeadsFilter(query: "  ").isEmpty)
    }

    @Test func countsLeaveClosedOut() {
        let counts = BeadsBoard.counts([issue("a"), issue("b", blocked: true), issue("c", status: "closed")])
        #expect(counts == [.todo: 1, .blocked: 1])
    }
}
