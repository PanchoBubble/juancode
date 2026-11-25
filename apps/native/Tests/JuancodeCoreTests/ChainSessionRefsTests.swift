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
}
