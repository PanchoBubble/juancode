import Testing
@testable import JuancodeApp

@Suite @MainActor struct PanelNavigationTests {
    @Test func onlyEnterActivates() {
        let nav = PanelNavigation()
        var opened: [String] = []
        var actions: [String] = []
        let rows = ["a", "b"].map { id in
            PanelNavigationRow(id: id, actions: [
                PanelRowAction(id: "close", label: "Close", perform: { actions.append(id) })
            ], open: { opened.append(id) })
        }
        nav.begin(.sessions, rows: rows)
        #expect(nav.handle(125))
        #expect(nav.handle(124))
        #expect(opened.isEmpty && actions.isEmpty)
        #expect(nav.handle(36))
        #expect(actions == ["b"] && opened.isEmpty)
        #expect(nav.handle(123))
        #expect(nav.handle(76))
        #expect(opened == ["b"])
        #expect(!nav.handle(0)) // ordinary typing has no panel meaning
        nav.end()
        #expect(nav.target == nil)
        #expect(nav.cursor.rowID == nil)
        #expect(opened == ["b"] && actions == ["b"])
    }

    @Test func updatesReplaceClosuresAndRemoveUnavailableActions() {
        let nav = PanelNavigation()
        var value = 0
        nav.begin(.prs, rows: [PanelNavigationRow(id: "a", actions: [
            PanelRowAction(id: "close", label: "Close", perform: { value = -1 })
        ], open: { value = 1 })])
        _ = nav.handle(124)
        nav.update([PanelNavigationRow(id: "a", open: { value = 2 })])
        #expect(nav.cursor.actionID == nil)
        _ = nav.handle(36)
        #expect(value == 2)
        nav.update([])
        _ = nav.handle(36)
        #expect(value == 2)
    }

    @Test func initialRowAndPanelSwitch() {
        let nav = PanelNavigation()
        nav.begin(.sessions, rows: [])
        nav.update([
            PanelNavigationRow(id: "a", open: {}),
            PanelNavigationRow(id: "active", isInitial: true, open: {})
        ])
        #expect(nav.cursor.rowID == "active")
        _ = nav.handle(126)
        nav.update([PanelNavigationRow(id: "a", open: {}),
                    PanelNavigationRow(id: "active", isInitial: true, open: {})])
        #expect(nav.cursor.rowID == "a")
        nav.begin(.chains, rows: [PanelNavigationRow(id: "chain", open: {})])
        #expect(nav.cursor.rowID == "chain")
        #expect(!nav.isFocused(.sessions, row: "chain"))
    }
}
