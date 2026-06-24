import Testing
@testable import JuancodeCore

/// Covers the pure grouping/sorting that backs the native Issues panel
/// (juancode-9s0): section assignment, priority-then-id ordering, and the
/// closed-issue handling.
@Suite struct BeadsGroupingTests {
    private func issue(_ id: String, status: String = "open", priority: Int = 2,
                       ready: Bool = false, blocked: Bool = false) -> BeadsIssue {
        BeadsIssue(id: id, title: id, status: status, priority: priority, issueType: "task",
                   parent: nil, dependencyCount: 0, dependentCount: 0, ready: ready, blocked: blocked)
    }

    @Test func sectionAssignmentPrefersReadyThenBlocked() {
        #expect(BeadsSection.of(issue("a", ready: true)) == .ready)
        #expect(BeadsSection.of(issue("b", blocked: true)) == .blocked)
        // Ready wins when both flags are (oddly) set.
        #expect(BeadsSection.of(issue("c", ready: true, blocked: true)) == .ready)
        #expect(BeadsSection.of(issue("d")) == .other)
        #expect(BeadsSection.of(issue("e", status: "closed", ready: true)) == .closed)
    }

    @Test func closedDroppedByDefaultIncludedWhenAsked() {
        let issues = [issue("open-1"), issue("done-1", status: "closed")]
        let withoutClosed = BeadsGrouping.grouped(issues)
        #expect(withoutClosed.map(\.section) == [.other])

        let withClosed = BeadsGrouping.grouped(issues, includeClosed: true)
        #expect(withClosed.map(\.section) == [.other, .closed])
    }

    @Test func sectionsOrderedReadyBlockedOther() {
        let issues = [
            issue("z-other"),
            issue("b-blocked", blocked: true),
            issue("r-ready", ready: true),
        ]
        let groups = BeadsGrouping.grouped(issues)
        #expect(groups.map(\.section) == [.ready, .blocked, .other])
    }

    @Test func emptySectionsOmitted() {
        let groups = BeadsGrouping.grouped([issue("only", ready: true)])
        #expect(groups.count == 1)
        #expect(groups.first?.section == .ready)
    }

    @Test func sortsByPriorityThenId() {
        let issues = [
            issue("a", priority: 3),
            issue("c", priority: 1),
            issue("b", priority: 1),
            issue("d", priority: 0),
        ]
        let group = BeadsGrouping.grouped(issues).first
        #expect(group?.issues.map(\.id) == ["d", "b", "c", "a"])
    }
}
