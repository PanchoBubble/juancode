import Foundation
import Testing
@testable import JuancodeCore

/// The chain graph (juancode-043.8): connections only where something recorded one,
/// unconnected members grouped apart, and a placement whose cards never overlap.
@Suite struct ChainGraphTests {
    private func session(_ id: String) -> ChainMember { ChainMember(kind: .session, ref: id) }
    private func ref(_ m: ChainMember) -> ChainGraphNodeID { .member(m.memberRef) }

    private func handoff(_ id: String, _ from: ChainHandoffOwner, _ to: ChainHandoffOwner,
                         chain: String = "board-access", issue: String? = nil, at: Int = 1,
                         state: ChainHandoffState = .pending) -> ChainHandoff {
        ChainHandoff(id: id, chainSlug: chain, source: from, target: to, beadsIssue: issue,
                     summary: "step \(id)", createdAt: at, updatedAt: at, state: state)
    }

    @Test func membershipAloneDrawsNoConnection() {
        // The board-access shape: sessions, a ticket and a PR with no handoff history.
        let chain = Chain(slug: "board-access", members: [
            session("s1"), session("s2"),
            ChainMember(kind: .beads, ref: "luma-12"),
            ChainMember(kind: .trackedPr, ref: "/repo#7"),
        ])
        let graph = ChainGraph.build(chain: chain, handoffs: [])
        #expect(graph.edges.isEmpty)
        #expect(!graph.hasRelationships)
        #expect(graph.unconnected == chain.members.map(ref))
    }

    @Test func handoffsConnectTheirOwnersAndLeaveTheRestUnconnected() {
        let a = session("a"), b = session("b"), c = session("c")
        let ticket = ChainMember(kind: .beads, ref: "juancode-1")
        let chain = Chain(slug: "board-access", members: [a, b, c, ticket])
        let graph = ChainGraph.build(chain: chain, handoffs: [
            handoff("h1", .session("a"), .session("b"), issue: "juancode-1"),
            // Another chain's record never draws here.
            handoff("x", .session("a"), .session("c"), chain: "other"),
        ])
        #expect(graph.groups.count == 1)
        #expect(graph.groups[0].columns == [[ref(a)], [ref(b)], [ref(ticket)]])
        #expect(graph.edges.map(\.id) == ["handoff:h1", "issue:h1"])
        #expect(graph.unconnected == [ref(c)])
    }

    @Test func humanAndOutsideOwnersAreTheirOwnNodes() {
        let a = session("a")
        let chain = Chain(slug: "board-access", members: [a])
        let graph = ChainGraph.build(chain: chain, handoffs: [
            handoff("h1", .human, .session("a")),
            handoff("h2", .session("a"), .session("elsewhere")),
            // A handoff naming an issue outside the chain links no ticket node.
            handoff("h3", .session("a"), .human, issue: "not-a-member"),
        ])
        #expect(graph.groups.count == 1)
        let nodes = Set(graph.groups[0].nodes)
        #expect(nodes == [ref(a), .human, .outsideSession("elsewhere")])
        #expect(graph.edges.count == 3)
        #expect(graph.unconnected.isEmpty)
    }

    @Test func trackingLinksNeedBothEndsInTheChain() {
        let s = session("s"), pr = ChainMember(kind: .trackedPr, ref: "/r#1")
        let chain = Chain(slug: "c", members: [s, pr])
        let graph = ChainGraph.build(chain: chain, handoffs: [], links: [
            ChainGraphLink(from: s.memberRef, to: pr.memberRef, kind: .watchesPr),
            ChainGraphLink(from: s.memberRef, to: pr.memberRef, kind: .watchesPr),
            ChainGraphLink(from: ChainMemberRef(kind: .session, ref: "gone"), to: pr.memberRef, kind: .watchesPr),
        ])
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].kind == .watchesPr)
        #expect(graph.groups[0].columns == [[ref(s)], [ref(pr)]])
    }

    @Test func aHandoffBackToAnEarlierOwnerStillDrawsWithoutLoopingTheLayout() {
        let a = session("a"), b = session("b")
        let chain = Chain(slug: "c", members: [a, b])
        let graph = ChainGraph.build(chain: chain, handoffs: [
            handoff("h1", .session("a"), .session("b"), chain: "c", at: 1, state: .closed),
            handoff("h2", .session("b"), .session("a"), chain: "c", at: 2),
            handoff("h3", .session("a"), .session("a"), chain: "c", at: 3),
        ])
        #expect(graph.edges.count == 3)
        #expect(graph.groups[0].columns == [[ref(a)], [ref(b)]])
        #expect(graph.edges.filter(\.isOpen).map(\.id) == ["handoff:h2", "handoff:h3"])
    }

    @Test func placementKeepsCardsApartAndWrapsUnconnectedToTheWidth() {
        let members = (0..<5).map { session("s\($0)") }
        let chain = Chain(slug: "c", members: members)
        let graph = ChainGraph.build(chain: chain, handoffs: [
            handoff("h", .session("s0"), .session("s1"), chain: "c"),
        ])
        let m = ChainGraphMetrics()
        let narrow = ChainGraphPlacement.place(graph, metrics: m, width: m.card.width + 2 * m.groupPadding)
        let frames = Array(narrow.nodes.values)
        #expect(frames.count == 5)
        for i in frames.indices {
            for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
        }
        // Unconnected wrap to one column on a narrow canvas: no wider than the connected group.
        #expect(narrow.boxes.count == 2)
        #expect(narrow.boxes[1].frame.width <= narrow.boxes[0].frame.width)
        let wide = ChainGraphPlacement.place(graph, metrics: m, width: 2000)
        #expect(wide.boxes[1].frame.height < narrow.boxes[1].frame.height)
        for f in wide.nodes.values { #expect(f.maxX <= wide.size.width && f.maxY <= wide.size.height) }
    }

    @Test func handoffsDecodeTheDaemonsShape() throws {
        let json = #"""
        {"id":"h1","chainSlug":"board-access","source":{"kind":"human"},
         "target":{"kind":"session","sessionId":"s1"},"beadsIssue":"juancode-043.1",
         "summary":"Continue","createdAt":1,"updatedAt":2,"state":"acknowledged",
         "successorId":"h2","delivery":"sent"}
        """#
        let h = try JSONDecoder().decode(ChainHandoff.self, from: Data(json.utf8))
        #expect(h.source == .human)
        #expect(h.target == .session("s1"))
        #expect(h.state == .acknowledged && h.delivery == .sent && h.isOpen)
        #expect(h.successorId == "h2" && h.predecessorId == nil)
        // The daemon defaults its stamped fields; so does the reader.
        let bare = try JSONDecoder().decode(ChainHandoff.self, from: Data(#"""
        {"id":"h","chainSlug":"c","source":{"kind":"human"},"target":{"kind":"human"},"summary":""}
        """#.utf8))
        #expect(bare.state == .pending && bare.delivery == .notSent && bare.createdAt == 0)
    }

    @Test func theHandoffBookConvergesOnWholeFrames() {
        var book = ChainHandoffBook()
        book.upsert(handoff("b", .human, .human, at: 2))
        book.replace(with: [handoff("a", .human, .human, at: 1), handoff("b", .human, .human, at: 2)])
        book.upsert(handoff("a", .human, .human, at: 1, state: .closed))
        book.upsert(handoff("z", .human, .human, chain: "other"))
        #expect(book.handoffs(in: "board-access").map(\.id) == ["a", "b"])
        #expect(book.handoffs(in: "board-access").first?.state == .closed)
    }
}
