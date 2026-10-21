import Testing
@testable import JuancodeCore

/// The chain detail view's grouping, search and row order.
@Suite struct ChainDetailTests {
    private func row(_ kind: ChainMemberKind, _ ref: String, _ title: String, group: ChainDetailGroup,
                     project: String? = nil, status: String? = nil, last: Int? = nil,
                     added: Int = 0, keywords: [String] = []) -> ChainDetailRow {
        ChainDetailRow(member: ChainMember(kind: kind, ref: ref, addedAt: added), group: group,
                       title: title, project: project, status: status, lastActivity: last,
                       keywords: keywords)
    }

    @Test func membersGroupByKindWithOraclesApart() {
        let isOracle = { (id: String) in id == "o1" }
        #expect(ChainDetailGroup.of(ChainMember(kind: .session, ref: "s1"), isOracle: isOracle) == .sessions)
        #expect(ChainDetailGroup.of(ChainMember(kind: .session, ref: "o1"), isOracle: isOracle) == .oracles)
        #expect(ChainDetailGroup.of(ChainMember(kind: .trackedPr, ref: "/r#1"), isOracle: isOracle) == .prs)
        #expect(ChainDetailGroup.of(ChainMember(kind: .beads, ref: "x-1"), isOracle: isOracle) == .tickets)
        #expect(ChainDetailGroup.of(ChainMember(kind: .linear, ref: "ENG-1"), isOracle: isOracle) == .tickets)
    }

    @Test func sectionsComeInGroupOrderAndSkipEmptyOnes() {
        let rows = [
            row(.beads, "x-1", "Fix it", group: .tickets),
            row(.session, "s1", "Agent", group: .sessions),
            row(.trackedPr, "/r#4", "PR four", group: .prs),
        ]
        #expect(ChainDetail.sections(rows, query: "").map(\.group) == [.sessions, .prs, .tickets])
        #expect(ChainDetail.sections([], query: "").isEmpty)
    }

    @Test func rowsAreMostRecentFirstThenJoinOrder() {
        let rows = [
            row(.session, "a", "A", group: .sessions, last: 10),
            row(.session, "b", "B", group: .sessions, last: 30),
            row(.session, "c", "C", group: .sessions, added: 10),
            row(.session, "d", "D", group: .sessions, last: 10),
        ]
        let order = ChainDetail.sections(rows, query: "").first?.rows.map(\.member.ref)
        #expect(order == ["b", "a", "c", "d"])
    }

    @Test func searchFiltersAcrossEveryGroupAndField() {
        let rows = [
            row(.session, "s1", "Refactor parser", group: .sessions, project: "juancode",
                status: "Working", keywords: ["claude"]),
            row(.session, "o1", "Oracle", group: .oracles, keywords: ["codex"]),
            row(.trackedPr, "/r/juancode#12", "Parser PR", group: .prs, project: "juancode"),
            row(.beads, "juancode-dbo.8", "Café detail", group: .tickets, status: "open"),
        ]
        func refs(_ q: String) -> [String] {
            ChainDetail.sections(rows, query: q).flatMap { $0.rows.map(\.member.ref) }
        }
        #expect(refs("PARSER") == ["s1", "/r/juancode#12"])
        #expect(refs("juancode") == ["s1", "/r/juancode#12", "juancode-dbo.8"])
        #expect(refs("juancode working") == ["s1"])
        #expect(refs("codex") == ["o1"])
        #expect(refs("cafe") == ["juancode-dbo.8"])
        #expect(refs("  ").count == 4)
        #expect(refs("nothing-here").isEmpty)
    }
}
