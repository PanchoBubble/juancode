import Testing
@testable import JuancodeCore

/// The chain view's tab decisions: where opening a chain lands, stepping between
/// tabs, and what survives the chain changing underneath the view.
@Suite struct ChainTabsTests {
    private let s1 = ChainMemberRef(kind: .session, ref: "s1")
    private let pr = ChainMemberRef(kind: .trackedPr, ref: "/repo#12")
    private let bd = ChainMemberRef(kind: .beads, ref: "proj-12.3")
    private let lin = ChainMemberRef(kind: .linear, ref: "ENG-7")

    private func chain(_ refs: [ChainMemberRef]) -> Chain {
        Chain(slug: "ship-it", members: refs.map { ChainMember(kind: $0.kind, ref: $0.ref) })
    }

    @Test func aKeyRoundTripsEvenWhenTheRefHasAColon() {
        #expect(ChainMemberRef(key: pr.key) == pr)
        let odd = ChainMemberRef(kind: .linear, ref: "a:b")
        #expect(ChainMemberRef(key: odd.key) == odd)
        #expect(ChainMemberRef(key: "nope:x") == nil)
        #expect(ChainMemberRef(key: "session:") == nil)
        #expect(ChainMemberRef(key: "session") == nil)
    }

    @Test func openingUsesTheRequestedMemberOrShowsTheOverview() {
        let c = chain([pr, s1, bd])
        #expect(ChainTabs.opening(in: c, requested: bd) == bd)
        #expect(ChainTabs.opening(in: c, requested: lin) == nil)
        #expect(ChainTabs.opening(in: c, requested: nil) == nil)
        #expect(ChainTabs.opening(in: chain([]), requested: nil) == nil)
    }

    @Test func steppingWrapsBothWays() {
        let c = chain([s1, pr, bd])
        #expect(ChainTabs.step(in: c, from: s1, by: 1) == pr)
        #expect(ChainTabs.step(in: c, from: bd, by: 1) == s1)
        #expect(ChainTabs.step(in: c, from: s1, by: -1) == bd)
        #expect(ChainTabs.step(in: c, from: nil, by: 1) == s1)
        #expect(ChainTabs.step(in: c, from: lin, by: -1) == bd)
        #expect(ChainTabs.step(in: chain([]), from: s1, by: 1) == nil)
    }

    @Test func aChangeKeepsTheTabOrFallsToItsNeighbour() {
        let old = chain([s1, pr, bd])
        #expect(ChainTabs.reconcile(pr, old: old, new: chain([lin, s1, pr, bd])) == pr)
        #expect(ChainTabs.reconcile(pr, old: old, new: chain([s1, bd])) == bd)
        #expect(ChainTabs.reconcile(bd, old: old, new: chain([s1, pr])) == pr)
        #expect(ChainTabs.reconcile(s1, old: old, new: chain([])) == nil)
        #expect(ChainTabs.reconcile(nil, old: nil, new: chain([lin])) == lin)
    }
}
