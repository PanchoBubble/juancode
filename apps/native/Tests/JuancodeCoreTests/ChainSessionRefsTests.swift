import Testing
@testable import JuancodeCore

/// A chain's token total covers its own sessions and every nested chain's, each once,
/// and a parent cycle still ends (juancode-8oa5.12).
@Suite struct ChainSessionRefsTests {
    private func chain(_ slug: String, _ refs: [String], parent: String? = nil) -> Chain {
        Chain(slug: slug, members: refs.map { ChainMember(kind: .session, ref: $0) }
            + [ChainMember(kind: .beads, ref: "not-a-session")], parent: parent)
    }

    @Test func includesNestedChainsAndSurvivesACycle() {
        let book = ChainBook([
            chain("loop", ["orch"], parent: "subsub"),
            chain("sub", ["impl"], parent: "loop"),
            chain("subsub", ["deep"], parent: "sub"),
            chain("other", ["elsewhere"]),
        ])
        #expect(book.sessionRefs(under: "sub") == ["impl", "deep", "orch"])
        #expect(book.sessionRefs(under: "other") == ["elsewhere"])
        #expect(book.sessionRefs(under: "missing").isEmpty)
    }

    @Test func attentionAndOutlineCoverEveryNestedChain() {
        // juancode-i38u: a parent's attention counts grandchildren; the rail outline
        // puts each nested chain under its parent, and a cycle still ends.
        let book = ChainBook([
            chain("loop", ["orch"]),
            chain("sub", ["impl"], parent: "loop"),
            chain("subsub", ["deep"], parent: "sub"),
            chain("orphan", ["o"], parent: "gone"),
        ])
        let waiting: Set = ["orch", "deep", "o"]
        let attention = ChainAttention(book.subtree(of: "loop"), waiting: { waiting.contains($0) }, deciding: { _ in false })
        #expect(attention.waitingInput == 2)
        let roots = book.chains.filter { !book.isNested($0) }
        #expect(book.outline(roots).map { "\($0.chain.slug):\($0.depth)" } == ["loop:0", "sub:1", "subsub:2", "orphan:0"])
        // juancode-a02s: an active child of a closed parent is an active root, once.
        var closedParent = chain("old", ["p"]); closedParent.state = .inactive
        let split = ChainBook([closedParent, chain("live", ["l"], parent: "old"), chain("kid", ["k"], parent: "live")])
        #expect(split.activeRoots.map(\.slug) == ["live"])
        #expect(split.outline(split.activeRoots).map(\.chain.slug) == ["live", "kid"])
        #expect(split.outline(split.inactive.filter { !split.isNested($0) }).map(\.chain.slug) == ["old"])
        // juancode-4hd4: the closed parent's attention leaves out that surfaced child (and
        // its subtree); the child's own row still counts it, and an active parent still does.
        let all: Set = ["p", "l", "k"]
        func closedScope(_ slug: String, _ book: ChainBook) -> Int {
            ChainAttention(book.subtree(of: slug, surfaced: false), waiting: { all.contains($0) }, deciding: { _ in false }).total
        }
        #expect(closedScope("old", split) == 1)
        #expect(closedScope("live", split) == 2)
        #expect(closedScope("old", ChainBook([chain("old", ["p"]), chain("live", ["l"], parent: "old")])) == 2)
        let cyclic = ChainBook([chain("a", [], parent: "b"), chain("b", [], parent: "a")])
        #expect(cyclic.subtree(of: "a").map(\.slug) == ["a", "b"])
    }
}
