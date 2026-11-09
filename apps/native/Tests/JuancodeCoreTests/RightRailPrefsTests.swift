import Foundation
import Testing
@testable import JuancodeCore

/// The rail shows exactly one destination (Worktree, or one Overview queue). Stored
/// accordion and Diff-panel layouts must land on a valid one, no old choice may make
/// a queue unreachable, and the shortcuts must report and open what is really shown.
@Suite struct RightRailPrefsTests {
    typealias P = RightRailPrefs

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let name = "RightRailPrefsTests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        return (d, { d.removePersistentDomain(forName: name) })
    }

    @Test func freshInstallStartsOnWorktree() {
        let s = P.migrated(P.Stored())
        #expect(s.view == .worktree)
        #expect(s.destination == "worktree")
        #expect(s.order == P.queues)
    }

    @Test func accordionWithWorktreeCollapsedOpensOverviewOnTheSelectedQueue() {
        let s = P.migrated(P.Stored(order: "tickets,prs,oracle,chains", schema: 2,
                                    collapsed: "worktree,oracle,chains", hidden: "",
                                    selected: "prs", pinned: "tickets"))
        #expect(s.view == .overview)
        #expect(s.queue == "prs")
        #expect(s.order == ["tickets", "prs", "oracle", "chains"])
    }

    @Test func accordionWithWorktreeOpenStaysOnWorktreeAndRemembersTheQueue() {
        let s = P.migrated(P.Stored(schema: 2, collapsed: "oracle,prs", selected: "tickets"))
        #expect(s.view == .worktree)
        #expect(s.queue == "tickets")
    }

    @Test func noSelectionFallsBackToTheFirstOpenQueueThenTheFirstInOrder() {
        let open = P.migrated(P.Stored(order: "chains,prs", schema: 2, collapsed: "worktree,chains"))
        #expect(open.queue == "prs")
        let allShut = P.migrated(P.Stored(order: "chains", schema: 2,
                                          collapsed: "worktree,oracle,prs,tickets,chains"))
        // Nothing open anywhere: Worktree, with the first queue remembered.
        #expect(allShut.view == .worktree)
        #expect(allShut.queue == "chains")
    }

    @Test func aHiddenQueueStaysReachable() {
        let s = P.migrated(P.Stored(schema: 2, collapsed: "worktree", hidden: "prs,tickets", selected: "prs"))
        #expect(s.order.contains("prs"))
        #expect(s.queue == "prs")
        #expect(s.showing("tickets").destination == "tickets")
    }

    @Test func diffPanelLayoutMigratesThroughWorktree() {
        // Schema 1: Diff hidden, PRs open → Worktree was off screen, so Overview.
        let s = P.migrated(P.Stored(order: "diff,prs,oracle", collapsed: "oracle", hidden: "diff"))
        #expect(s.view == .overview)
        #expect(s.queue == "prs")
        #expect(!s.order.contains("diff"))
        // Schema 1 with Diff open: Worktree.
        #expect(P.migrated(P.Stored(order: "diff,prs", collapsed: "prs")).view == .worktree)
    }

    @Test func garbageHealsToAValidDestination() {
        let s = P.state(P.Stored(view: "files", queue: "diff", order: "x,prs,prs", schema: 3))
        #expect(s.view == .worktree)
        #expect(s.order == ["prs", "oracle", "tickets", "chains"])
        #expect(s.queue == "prs")
    }

    @Test func showingAQueueSwitchesToOverviewAndWorktreeSwitchesBack() {
        let s = P.State().showing("chains")
        #expect(s.view == .overview && s.queue == "chains")
        #expect(s.isVisible("chains") && !s.isVisible("prs") && !s.isVisible("worktree"))
        let back = s.showing("worktree")
        #expect(back.isVisible("worktree") && !back.isVisible("chains"))
        #expect(back.queue == "chains")
        #expect(s.showing("diff") == s)
    }

    @Test func migrateRewritesOnceAndDropsAccordionKeys() throws {
        let (d, done) = try defaults()
        defer { done() }
        P.Stored(order: "prs,oracle", schema: 2, collapsed: "worktree", heights: "prs:200",
                 selected: "prs", pinned: "oracle").write(to: d)
        #expect(P.migrate(d))
        #expect(!P.migrate(d))
        #expect(d.string(forKey: "rightRail.collapsed") == nil)
        #expect(d.string(forKey: "rightRail.heights") == nil)
        #expect(d.string(forKey: "rightRail.pinned") == nil)
        #expect(d.string(forKey: P.viewKey) == "overview")
        #expect(d.string(forKey: P.queueKey) == "prs")
    }

    @Test func shortcutsOpenTheRightTabAndReportOnlyTheVisibleDestination() throws {
        let (d, done) = try defaults()
        defer { done() }
        d.set(false, forKey: P.railShownKey)
        #expect(!P.isOpen("worktree", in: d))
        P.setOpen("tickets", true, in: d)
        #expect(P.isOpen("tickets", in: d))
        #expect(!P.isOpen("worktree", in: d))
        #expect(!P.isOpen("prs", in: d))
        P.setOpen("worktree", true, in: d)
        #expect(P.isOpen("worktree", in: d))
        #expect(!P.isOpen("tickets", in: d))
    }

    @Test func hidingTheVisibleDestinationHidesTheRailAndNothingElseDoes() throws {
        let (d, done) = try defaults()
        defer { done() }
        P.setOpen("worktree", true, in: d)
        // ⌘C off while Overview is up must not flip the user to another view.
        P.setOpen("prs", true, in: d)
        P.setOpen("worktree", false, in: d)
        #expect(P.isOpen("prs", in: d))
        // ⌘C on, then off: Worktree shows, then the rail hides; on again shows it.
        P.setOpen("worktree", true, in: d)
        P.setOpen("worktree", false, in: d)
        #expect(!P.isOpen("worktree", in: d))
        #expect(d.bool(forKey: P.railShownKey) == false)
        P.setOpen("worktree", true, in: d)
        #expect(P.isOpen("worktree", in: d))
    }
    @Test func stackRestoresVisibilityAndOrderIndependentlyOfTabs() throws {
        let (d, done) = try defaults()
        defer { done() }
        let stack = P.Stack().setting("tickets", shown: true).moving("tickets", before: "oracle")
        P.storeStack(stack, in: d)
        P.stored(P.State().showing("chains")).write(to: d)
        #expect(P.stack(in: d) == stack)
        #expect(P.stack(in: d).shown == ["tickets", "oracle", "prs"])
        #expect(P.state(P.Stored(d)).destination == "chains")
    }

    @Test func stackedShortcutsPreserveOtherPanelsAndTheRail() throws {
        let (d, done) = try defaults()
        defer { done() }
        d.set(true, forKey: P.stackedKey)
        P.setOpen("worktree", true, in: d)
        #expect(P.isOpen("worktree", in: d))
        #expect(P.isOpen("oracle", in: d))
        #expect(P.isOpen("prs", in: d))
        P.setOpen("worktree", false, in: d)
        #expect(!P.isOpen("worktree", in: d))
        #expect(P.isOpen("prs", in: d))
        #expect(d.bool(forKey: P.railShownKey))
        d.set(false, forKey: P.railShownKey)
        P.setOpen("tickets", true, in: d)
        #expect(P.isOpen("tickets", in: d))
        #expect(P.isOpen("prs", in: d))
    }

    @Test func emptyStackAndMalformedPreferencesRestoreSafely() throws {
        let (d, done) = try defaults()
        defer { done() }
        let empty = P.Stack(order: ["tickets", "garbage", "tickets"], visible: [])
        P.storeStack(empty, in: d)
        #expect(P.stack(in: d).shown.isEmpty)
        #expect(P.stack(in: d).order == ["tickets", "worktree", "oracle", "prs", "chains"])
        #expect(empty.moving("garbage", before: "oracle") == empty)
        #expect(empty.setting("garbage", shown: true) == empty)
    }

}
