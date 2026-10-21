import Testing
@testable import JuancodeCore

/// The right rail's stored order / collapsed / hidden lists (juancode-48m).
@Suite struct RightRailPrefsTests {
    enum Panel: String, CaseIterable { case oracle, prs, diff, chains }
    let known = Panel.allCases

    @Test func orderHealsUnknownDuplicateAndMissingNames() {
        #expect(RightRailPrefs.order(from: "diff,bogus,diff,oracle", known: known) == [.diff, .oracle, .prs, .chains])
        #expect(RightRailPrefs.order(from: "", known: known) == known)
    }

    @Test func aPanelNewToThisBuildIsVisibleUntilHidden() {
        // A hidden list written before `chains` existed doesn't name it, so it shows.
        let hidden: Set<Panel> = RightRailPrefs.set(from: "prs")
        #expect(hidden == [.prs])
        #expect(!hidden.contains(.chains))
    }

    @Test func setDropsUnknownNamesAndRawIsInKnownOrder() {
        let s: Set<Panel> = RightRailPrefs.set(from: "chains,gone,oracle")
        #expect(s == [.chains, .oracle])
        #expect(RightRailPrefs.raw(s, known: known) == "oracle,chains")
        #expect(RightRailPrefs.raw(Set<Panel>(), known: known) == "")
    }

    @Test func aHiddenPanelIsNotOpen() {
        #expect(RightRailPrefs.isOpen("diff", railShown: true, collapsedRaw: "", hiddenRaw: ""))
        #expect(!RightRailPrefs.isOpen("diff", railShown: true, collapsedRaw: "", hiddenRaw: "prs,diff"))
        #expect(!RightRailPrefs.isOpen("diff", railShown: true, collapsedRaw: "diff", hiddenRaw: ""))
        #expect(!RightRailPrefs.isOpen("diff", railShown: false, collapsedRaw: "", hiddenRaw: ""))
    }

    @Test func openingAHiddenPanelUnhidesAndExpandsIt() {
        let next = RightRailPrefs.setting("diff", open: true, collapsedRaw: "oracle,diff", hiddenRaw: "diff,prs")
        #expect(next.collapsed == "oracle")
        #expect(next.hidden == "prs")
    }

    @Test func collapsingLeavesTheHiddenListAlone() {
        let next = RightRailPrefs.setting("diff", open: false, collapsedRaw: "oracle", hiddenRaw: "prs")
        #expect(next.collapsed == "oracle,diff")
        #expect(next.hidden == "prs")
        let again = RightRailPrefs.setting("diff", open: false, collapsedRaw: next.collapsed, hiddenRaw: next.hidden)
        #expect(again.collapsed == "oracle,diff")
    }
}
