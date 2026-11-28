import Testing
@testable import JuancodeApp

@Suite @MainActor struct PanelNavigationTests {
    @Test func sessionKeysActOnlyOnTheFocusedRow() {
        let nav = PanelNavigation()
        var calls: [String] = []
        nav.begin(.sessions, rows: [
            PanelNavigationRow(id: "project", actions: [
                PanelRowAction(id: "new", label: "New", perform: { calls.append("new") })
            ], open: {}),
            PanelNavigationRow(id: "session", actions: ["close", "delete", "rename", "pin", "editor"].map { id in
                PanelRowAction(id: id, label: id, perform: { calls.append(id) })
            }, open: {})
        ])
        #expect(nav.handle(8)) // c on a project must not close or move
        #expect(nav.cursor.rowID == "project")
        #expect(nav.handle(45))
        #expect(calls == ["new"])
        #expect(nav.handle(125))
        #expect(nav.handle(8))
        #expect(nav.handle(2))
        #expect(nav.handle(14))
        #expect(nav.handle(35))
        #expect(nav.performAction("editor"))
        #expect(calls == ["new", "close", "delete", "rename", "pin", "editor"])
        nav.update([PanelNavigationRow(id: "session", open: {})])
        #expect(nav.handle(8)) // unavailable close cannot call a stale action
        #expect(nav.handle(2))
        #expect(calls.count == 6)
        nav.update([PanelNavigationRow(id: "project", open: {}), PanelNavigationRow(id: "session", open: {})])
        #expect(nav.handle(40)) // k navigates up again
        #expect(nav.cursor.rowID == "project")
        #expect(calls.count == 6)
        nav.end()
        #expect(!nav.performAction("editor"))
    }

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

    @Test func vimMotionsBrowseWithoutActivating() {
        let nav = PanelNavigation()
        var opened = false
        var acted = false
        nav.begin(.prs, rows: [
            PanelNavigationRow(id: "repo", open: {}),
            PanelNavigationRow(id: "pr", actions: [
                PanelRowAction(id: "review", label: "Review", perform: { acted = true })
            ], open: { opened = true })
        ])
        #expect(nav.handle(38)) // j
        #expect(nav.cursor.rowID == "pr")
        #expect(nav.handle(37)) // l
        #expect(nav.cursor.actionID == "review")
        #expect(!opened && !acted)
        #expect(nav.handle(36))
        #expect(acted && !opened)
        #expect(nav.handle(4)) // h
        #expect(nav.cursor.actionID == nil)
        #expect(nav.handle(36))
        #expect(opened)
        #expect(nav.handle(40)) // k
        #expect(nav.cursor.rowID == "repo")
        nav.end()
        #expect(nav.target == nil)
    }

    @Test func horizontalNavigationSelectsActionsAndResetsOnRowChange() {
        let nav = PanelNavigation()
        var activated: [String] = []
        let actions = ["tracking", "agent", "review", "github"].map { id in
            PanelRowAction(id: id, label: id, perform: { activated.append(id) })
        }
        nav.begin(.prs, rows: [
            PanelNavigationRow(id: "local", actions: actions, open: { activated.append("row") }),
            PanelNavigationRow(id: "remote", actions: [actions[3]], open: {})
        ])
        for id in ["tracking", "agent", "review", "github", "github"] {
            #expect(nav.handle(37)) // l, clamped at the last available action
            #expect(nav.cursor.actionID == id)
            #expect(nav.selectedActionLabel == id)
        }
        #expect(activated.isEmpty)
        #expect(nav.handle(36))
        #expect(activated == ["github"])
        #expect(nav.handle(4)) // h
        #expect(nav.cursor.actionID == "review")
        #expect(nav.handle(36))
        #expect(activated == ["github", "review"])
        #expect(nav.handle(38)) // j clears the action when moving to another row
        #expect(nav.cursor.actionID == nil)
        #expect(nav.handle(37))
        #expect(nav.cursor.actionID == "github")
        #expect(nav.handle(36))
        #expect(activated == ["github", "review", "github"])
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
