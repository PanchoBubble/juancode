import XCTest
@testable import JuancodeServices

final class TerminalPanelModelTests: XCTestCase {
    func testStartsEmpty() {
        let m = TerminalPanelModel()
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.activeTabID)
        XCTAssertNil(m.activeTab)
        XCTAssertTrue(m.allPanes().isEmpty)
    }

    func testAddTabMakesItActiveWithOnePane() {
        var m = TerminalPanelModel()
        let pane = m.addTab()
        XCTAssertEqual(m.tabs.count, 1)
        XCTAssertEqual(m.activeTabID, m.tabs[0].id)
        XCTAssertEqual(m.tabs[0].panes, [pane])
        XCTAssertFalse(m.tabs[0].isSplit)
        XCTAssertEqual(m.tabs[0].title, "Terminal 1")
    }

    func testAddTabsGetSequentialTitlesAndActivateLatest() {
        var m = TerminalPanelModel()
        m.addTab(); m.addTab(); m.addTab()
        XCTAssertEqual(m.tabs.map(\.title), ["Terminal 1", "Terminal 2", "Terminal 3"])
        XCTAssertEqual(m.activeTabID, m.tabs[2].id)
    }

    func testSelectTab() {
        var m = TerminalPanelModel()
        m.addTab()
        let first = m.tabs[0].id
        m.addTab()
        m.selectTab(first)
        XCTAssertEqual(m.activeTabID, first)
        // Selecting a non-existent tab is a no-op.
        m.selectTab(UUID())
        XCTAssertEqual(m.activeTabID, first)
    }

    func testSplitActiveTabAddsSecondPane() {
        var m = TerminalPanelModel()
        let p1 = m.addTab()
        let p2 = m.splitActiveTab()
        XCTAssertNotNil(p2)
        XCTAssertEqual(m.tabs[0].panes, [p1, p2])
        XCTAssertTrue(m.tabs[0].isSplit)
    }

    func testSplitIsCappedAtTwoPanes() {
        var m = TerminalPanelModel()
        m.addTab()
        XCTAssertNotNil(m.splitActiveTab())
        XCTAssertNil(m.splitActiveTab(), "already split: no third pane")
        XCTAssertEqual(m.tabs[0].panes.count, 2)
    }

    func testSplitWithNoActiveTabReturnsNil() {
        var m = TerminalPanelModel()
        XCTAssertNil(m.splitActiveTab())
    }

    func testUnsplitRemovesSecondPane() {
        var m = TerminalPanelModel()
        let p1 = m.addTab()
        let p2 = m.splitActiveTab()
        let removed = m.unsplitActiveTab()
        XCTAssertEqual(removed, p2)
        XCTAssertEqual(m.tabs[0].panes, [p1])
        XCTAssertNil(m.unsplitActiveTab(), "nothing left to collapse")
    }

    func testCloseTabReturnsItsOrphanedPanes() {
        var m = TerminalPanelModel()
        let p1 = m.addTab()
        let p2 = m.splitActiveTab()!
        let orphaned = m.closeTab(m.tabs[0].id)
        XCTAssertEqual(Set(orphaned), Set([p1, p2]))
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.activeTabID)
    }

    func testCloseActiveTabPicksNeighbour() {
        var m = TerminalPanelModel()
        m.addTab() // Terminal 1
        m.addTab() // Terminal 2
        m.addTab() // Terminal 3 (active)
        let middle = m.tabs[1].id
        m.selectTab(middle)
        m.closeTab(middle)
        // Removed index 1 -> neighbour at min(1, count-1) = index 1 (was Terminal 3).
        XCTAssertEqual(m.tabs.count, 2)
        XCTAssertEqual(m.activeTabID, m.tabs[1].id)
        XCTAssertEqual(m.tabs.map(\.title), ["Terminal 1", "Terminal 3"])
    }

    func testCloseInactiveTabKeepsActive() {
        var m = TerminalPanelModel()
        m.addTab()
        let first = m.tabs[0].id
        m.addTab()
        let second = m.tabs[1].id
        m.selectTab(second)
        m.closeTab(first)
        XCTAssertEqual(m.activeTabID, second)
        XCTAssertEqual(m.tabs.count, 1)
    }

    func testCloseLastTabClearsSelection() {
        var m = TerminalPanelModel()
        m.addTab()
        m.closeTab(m.tabs[0].id)
        XCTAssertNil(m.activeTabID)
        XCTAssertTrue(m.isEmpty)
    }

    func testTitleNeverCollidesAfterClose() {
        var m = TerminalPanelModel()
        m.addTab() // Terminal 1
        m.addTab() // Terminal 2
        m.closeTab(m.tabs[0].id) // remove Terminal 1, leaving Terminal 2
        m.addTab() // count is 1 -> candidate "Terminal 2" collides -> "Terminal 3"
        XCTAssertEqual(Set(m.tabs.map(\.title)).count, m.tabs.count, "titles unique")
        XCTAssertTrue(m.tabs.map(\.title).contains("Terminal 3"))
    }

    func testAllPanesAcrossTabs() {
        var m = TerminalPanelModel()
        let a = m.addTab()
        let b = m.splitActiveTab()!
        let c = m.addTab()
        XCTAssertEqual(Set(m.allPanes()), Set([a, b, c]))
    }
}
