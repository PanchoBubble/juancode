import Testing
@testable import JuancodeCore

/// The in-place agent | editor tabs a session gets from the `</>` button.
@Suite struct SessionEditorTabsTests {
    @Test func aSessionWithNoEditorShowsItsAgent() {
        let tabs = SessionEditorTabs()
        #expect(tabs.activeTab(for: "s1") == .agent)
        #expect(!tabs.hasEditor("s1"))
    }

    @Test func openingAnEditorBringsItToTheFront() {
        var tabs = SessionEditorTabs()
        let replaced = tabs.opened("e1", for: "s1")
        #expect(replaced == nil)
        #expect(tabs.activeTab(for: "s1") == .editor)
        #expect(tabs.editorId(for: "s1") == "e1")
        #expect(tabs.activeTab(for: "s2") == .agent)
    }

    @Test func switchingTabsKeepsTheEditor() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1")
        tabs.select(.agent, for: "s1")
        #expect(tabs.activeTab(for: "s1") == .agent)
        #expect(tabs.editorId(for: "s1") == "e1")
        let first = tabs.toggle(for: "s1")
        let second = tabs.toggle(for: "s1")
        #expect(first == .editor)
        #expect(second == .agent)
    }

    @Test func theEditorTabCannotBeSelectedWithoutAnEditor() {
        var tabs = SessionEditorTabs()
        let selected = tabs.select(.editor, for: "s1")
        let flipped = tabs.toggle(for: "s1")
        #expect(!selected)
        #expect(flipped == .agent)
    }

    @Test func anExitDropsBackToTheAgent() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1")
        let owner = tabs.exited("e1")
        #expect(owner == "s1")
        #expect(tabs.activeTab(for: "s1") == .agent)
        #expect(!tabs.hasEditor("s1"))
        // A late second exit for the same pty is nobody's.
        let again = tabs.exited("e1")
        #expect(again == nil)
    }

    @Test func aReplacedEditorsLateExitLeavesTheNewOneAlone() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1")
        let replaced = tabs.opened("e2", for: "s1")
        let lateExit = tabs.exited("e1")
        #expect(replaced == "e1")
        #expect(lateExit == nil)
        #expect(tabs.editorId(for: "s1") == "e2")
        #expect(tabs.activeTab(for: "s1") == .editor)
    }

    @Test func removingASessionHandsBackItsEditorToKill() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1")
        tabs.opened("e2", for: "s2")
        let removed = tabs.remove(session: "s1")
        let again = tabs.remove(session: "s1")
        #expect(removed == "e1")
        #expect(again == nil)
        #expect(tabs.entries.map(\.sessionId) == ["s2"])
    }

    @Test func entriesAreStablyOrdered() {
        var tabs = SessionEditorTabs()
        tabs.opened("b", for: "s1")
        tabs.opened("a", for: "s2")
        #expect(tabs.entries.map(\.editorId) == ["a", "b"])
    }
}
