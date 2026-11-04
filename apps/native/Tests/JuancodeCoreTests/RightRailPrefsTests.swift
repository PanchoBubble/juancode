import Foundation
import Testing
@testable import JuancodeCore

/// The rail's stored choices must survive the schema-2 redesign (Diff folded into an
/// anchored Worktree) and the accordion rules must never lose or strand a section.
@Suite struct RightRailPrefsTests {
    typealias P = RightRailPrefs

    @Test func freshInstallCollapsesOnlyChains() {
        let s = P.state(P.migrated(P.Stored()))
        #expect(s.order == ["oracle", "prs", "tickets", "chains"])
        #expect(s.collapsed == ["chains"])
        #expect(s.isOpen("worktree"))
        #expect(s.selected == "oracle")
    }

    @Test func schemaOneChoicesCarryOverAndDiffBecomesWorktree() {
        let old = P.Stored(order: "tickets,diff,prs,oracle,chains",
                           collapsed: "diff,oracle",
                           hidden: "prs",
                           heights: "diff:240,tickets:180,bogus:9")
        let new = P.migrated(old)
        #expect(new.schema == P.schema)
        let s = P.state(new)
        #expect(s.order == ["tickets", "prs", "oracle", "chains"])
        #expect(s.collapsed == ["worktree", "oracle"])
        #expect(s.hidden == ["prs"])
        #expect(s.heights == ["worktree": 240, "tickets": 180])
        // Chains was open in schema 1 and stays open: a saved choice wins the default.
        #expect(s.isOpen("chains"))
        #expect(s.selected == "tickets")
    }

    @Test func hiddenDiffBecomesCollapsedWorktreeNeverHidden() {
        let s = P.state(P.migrated(P.Stored(collapsed: "", hidden: "diff,chains")))
        #expect(s.hidden == ["chains"])
        #expect(s.collapsed == ["worktree"])
        #expect(!s.settingHidden("worktree", true).hidden.contains("worktree"))
    }

    @Test func readingSchemaOneWithoutMigratingNeverShowsDiff() {
        let s = P.state(P.Stored(order: "diff,prs", collapsed: "diff"))
        #expect(!s.order.contains("diff"))
        #expect(s.collapsed.contains("worktree"))
    }

    @Test func migrationIsIdempotentAndKeepsUserHeightOverDiffs() {
        let once = P.migrated(P.Stored(heights: "worktree:100,diff:300"))
        #expect(P.migrated(once) == once)
        #expect(P.state(once).heights["worktree"] == 100)
        #expect(P.state(P.stored(P.state(once))) == P.state(once))
    }

    @Test func openingAGlobalSelectsItAndKeepsOnlyThePinnedOneOpen() {
        var s = P.State(collapsed: [])
        s = s.togglingPin("tickets").opening("prs")
        #expect(s.pinned == "tickets")
        s = s.opening("oracle")
        #expect(s.selected == "oracle")
        #expect(s.expanded == ["worktree", "oracle", "tickets"])
        #expect(s.filler == "oracle")
        // Worktree is contextual: global accordion moves never collapse it.
        #expect(s.isOpen("worktree"))
    }

    @Test func collapsingTheSelectedHandsSpaceToThePinned() {
        let s = P.State(collapsed: []).togglingPin("chains").opening("prs").collapsing("prs")
        #expect(s.selected == "chains")
        #expect(s.pinned == nil)
        #expect(s.filler == "chains")
    }

    @Test func pinOnlyAppliesToAnOpenNonSelectedGlobal() {
        let s = P.State(collapsed: []).opening("prs")
        #expect(s.togglingPin("prs").pinned == nil)
        #expect(s.togglingPin("worktree").pinned == nil)
        #expect(s.togglingPin("oracle").pinned == nil) // collapsed by opening prs
        #expect(s.togglingPin("oracle").togglingPin("oracle") == s)
    }

    @Test func openingAHiddenSectionByShortcutRestoresIt() {
        let s = P.State(hidden: ["tickets"]).opening("tickets")
        #expect(!s.hidden.contains("tickets"))
        #expect(s.selected == "tickets")
    }

    @Test func hidingTheSelectedDropsItsSelection() {
        let s = P.State(collapsed: []).opening("prs").settingHidden("prs", true)
        #expect(s.selected == nil)
        #expect(s.filler == "worktree")
    }

    @Test func worktreeStaysAnchoredWhileGlobalsReorder() {
        let s = P.State()
        #expect(s.moving("worktree", to: "prs") == s)
        #expect(s.moving("chains", to: "worktree").order.first == "chains")
        #expect(s.moving("tickets", to: "oracle").order == ["tickets", "oracle", "prs", "chains"])
    }

    @Test func expandAllRespectsTheAccordion() {
        let s = P.State(collapsed: []).togglingPin("prs").opening("tickets")
            .settingAllCollapsed(true)
        #expect(s.expanded.isEmpty)
        let open = s.settingAllCollapsed(false)
        #expect(open.expanded == ["worktree", "prs", "tickets"])
    }

    @Test func shortcutsWriteWhatTheRailReads() throws {
        let name = "RightRailPrefsTests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set("diff,tickets", forKey: P.collapsedKey)
        d.set(false, forKey: P.railShownKey)
        #expect(!P.isOpen("worktree", in: d))
        P.setOpen("worktree", true, in: d)
        #expect(P.isOpen("worktree", in: d))
        #expect(d.integer(forKey: P.schemaKey) == P.schema)
        P.setOpen("tickets", true, in: d)
        #expect(P.state(P.Stored(d)).selected == "tickets")
        #expect(!P.migrate(d))
    }
}
