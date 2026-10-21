import Testing
@testable import JuancodeCore

/// The Chains rail panel's per-chain attention counts and its Inactive ordering.
@Suite struct ChainAttentionTests {
    @Test func countsWaitingSessionsAndDecidingPrsOnly() {
        let chain = Chain(slug: "ship-it", members: [
            ChainMember(kind: .session, ref: "s1"),
            ChainMember(kind: .session, ref: "s2"),
            ChainMember(kind: .trackedPr, ref: "/repo#12"),
            ChainMember(kind: .trackedPr, ref: "/repo#13"),
            // Same ref under another kind must not count as the session.
            ChainMember(kind: .beads, ref: "s1"),
        ])
        let a = ChainAttention(chain, waiting: { $0 == "s1" }, deciding: { $0 == "/repo#13" })
        #expect(a == ChainAttention(waitingInput: 1, needsDecision: 1))
        #expect(a.total == 2)
        #expect(!a.isEmpty)
        #expect(ChainAttention(chain, waiting: { _ in false }, deciding: { _ in false }).isEmpty)
    }

    @Test func inactiveIsClosedChainsMostRecentlyClosedFirst() {
        let book = ChainBook([
            Chain(slug: "a", state: .inactive, closedAt: 10),
            Chain(slug: "b"),
            Chain(slug: "c", state: .inactive, closedAt: 30),
            Chain(slug: "d", state: .inactive, closedAt: nil),
        ])
        #expect(book.inactive.map(\.slug) == ["c", "a", "d"])
        #expect(book.active.map(\.slug) == ["b"])
    }
}
