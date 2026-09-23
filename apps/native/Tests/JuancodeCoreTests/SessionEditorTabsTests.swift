import Foundation
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

    @Test func aSplitShowsBothTabsAndKeepsTrackOfTheFocusedOne() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1")
        let split = tabs.split(.sideBySide, for: "s1")
        tabs.select(.agent, for: "s1")
        #expect(split)
        #expect(tabs.splitAxis(for: "s1") == .sideBySide)
        #expect(tabs.isShown(.agent, for: "s1"))
        #expect(tabs.isShown(.editor, for: "s1"))
        #expect(tabs.activeTab(for: "s1") == .agent)
    }

    @Test func aSessionWithoutAnEditorCannotSplit() {
        var tabs = SessionEditorTabs()
        let split = tabs.split(.stacked, for: "s1")
        #expect(!split)
        #expect(tabs.splitAxis(for: "s1") == nil)
        #expect(!tabs.isShown(.editor, for: "s1"))
    }

    @Test func anEditorCanOpenStraightIntoASplit() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1", split: .stacked)
        #expect(tabs.splitAxis(for: "s1") == .stacked)
        #expect(tabs.activeTab(for: "s1") == .editor)
    }

    @Test func closingTheAgentPaneLeavesTheEditorInFront() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1", split: .sideBySide)
        tabs.unsplit(for: "s1", keeping: .editor)
        #expect(tabs.splitAxis(for: "s1") == nil)
        #expect(tabs.isShown(.editor, for: "s1"))
        #expect(!tabs.isShown(.agent, for: "s1"))
    }

    @Test func theEditorExitingEndsTheSplitAndTheAgentSurvives() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1", split: .sideBySide)
        tabs.exited("e1")
        #expect(tabs.splitAxis(for: "s1") == nil)
        #expect(tabs.isShown(.agent, for: "s1"))
        // A fresh editor does not inherit the old split unless asked.
        tabs.opened("e2", for: "s1")
        #expect(tabs.splitAxis(for: "s1") == nil)
    }

    @Test func removingASessionForgetsItsSplit() {
        var tabs = SessionEditorTabs()
        tabs.opened("e1", for: "s1", split: .stacked)
        tabs.remove(session: "s1")
        tabs.opened("e2", for: "s1")
        #expect(tabs.splitAxis(for: "s1") == nil)
    }
}

/// The split layout a project remembers.
@Suite struct ProjectPaneLayoutsTests {
    @Test func anUnknownProjectGetsTheStandardLayout() {
        #expect(ProjectPaneLayouts().layout(for: "/p") == .standard)
    }

    @Test func layoutsArePerProjectAndSurviveARoundTrip() {
        var layouts = ProjectPaneLayouts()
        layouts.update("/a") { $0.split = true; $0.axis = .stacked; $0.fraction = 0.3 }
        let back = ProjectPaneLayouts.decode(layouts.encoded())
        #expect(back.layout(for: "/a") == SessionPaneLayout(split: true, axis: .stacked, fraction: 0.3))
        #expect(back.layout(for: "/b") == .standard)
    }

    @Test func theFractionIsClampedSoNeitherPaneCollapses() {
        var layouts = ProjectPaneLayouts()
        layouts.update("/a") { $0.fraction = 0.01 }
        #expect(layouts.layout(for: "/a").fraction == 0.2)
        layouts.update("/a") { $0.fraction = .nan }
        #expect(layouts.layout(for: "/a").fraction == 0.5)
    }

    @Test func garbageDecodesToNothingRemembered() {
        #expect(ProjectPaneLayouts.decode(Data("nope".utf8)) == ProjectPaneLayouts())
        #expect(ProjectPaneLayouts.decode(nil) == ProjectPaneLayouts())
    }
}

/// Where the split puts each pane.
@Suite struct SessionSplitFramesTests {
    let size = CGSize(width: 1008, height: 600)

    @Test func unsplitTheAgentFillsThePaneAndTheEditorClearsTheShellPanel() {
        let f = SessionSplitFrames.layout(size: size, axis: nil, fraction: 0.5, bottomInset: 200)
        #expect(f.agent == CGRect(x: 0, y: 0, width: 1008, height: 600))
        #expect(f.editor == CGRect(x: 0, y: 0, width: 1008, height: 400))
    }

    @Test func sideBySideSharesTheWidthAroundTheGap() {
        let f = SessionSplitFrames.layout(size: size, axis: .sideBySide, fraction: 0.25, bottomInset: 0)
        #expect(f.agent == CGRect(x: 0, y: 0, width: 250, height: 600))
        #expect(f.divider == CGRect(x: 250, y: 0, width: 8, height: 600))
        #expect(f.editor == CGRect(x: 258, y: 0, width: 750, height: 600))
    }

    @Test func stackedSharesOnlyTheHeightAboveTheShellPanel() {
        let f = SessionSplitFrames.layout(size: size, axis: .stacked, fraction: 0.5, bottomInset: 192)
        #expect(f.agent == CGRect(x: 0, y: 0, width: 1008, height: 200))
        #expect(f.editor == CGRect(x: 0, y: 208, width: 1008, height: 200))
        #expect(f.editor.maxY == CGFloat(600 - 192))
    }

    @Test func closingASplitGivesTheSurvivorThePaneBack() {
        let split = SessionSplitFrames.layout(size: size, axis: .sideBySide, fraction: 0.5, bottomInset: 0)
        let closed = SessionSplitFrames.layout(size: size, axis: nil, fraction: 0.5, bottomInset: 0)
        #expect(split.agent.width < size.width)
        #expect(closed.agent.size == size)
    }

    @Test func aDividerDragMapsBackToTheFractionThatDrawsIt() {
        let f = SessionSplitFrames.fraction(forAgentExtent: 300, axis: .sideBySide, size: size, bottomInset: 0)
        #expect(f == 0.3)
        let laidOut = SessionSplitFrames.layout(size: size, axis: .sideBySide, fraction: f, bottomInset: 0)
        #expect(laidOut.agent.width == 300)
        let clamped = SessionSplitFrames.fraction(forAgentExtent: 5000, axis: .stacked, size: size, bottomInset: 0)
        #expect(clamped == 0.8)
    }
}
