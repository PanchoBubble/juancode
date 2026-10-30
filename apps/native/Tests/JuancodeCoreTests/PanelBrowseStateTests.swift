import Testing
@testable import JuancodeCore

@Suite struct PanelBrowseStateTests {
    @Test func browsingAndActions() {
        var state = PanelBrowseState()
        state.reconcile(["a", "b"], actions: [])
        #expect(state.rowID == "a")
        state.moveAction(1, actions: ["delete", "open"])
        #expect(state.actionID == "delete")
        state.moveAction(-1, actions: ["delete", "open"])
        #expect(state.actionID == nil)
        state.moveAction(1, actions: ["delete"])
        state.moveRow(1)
        #expect(state.rowID == "b")
        #expect(state.actionID == nil)
        state.moveRow(1)
        #expect(state.rowID == "b")
    }
    @Test func liveDeletionAndReordering() {
        var state = PanelBrowseState()
        state.reconcile(["a", "b", "c"], actions: [])
        state.moveRow(1)
        state.moveAction(1, actions: ["close"])
        state.reconcile(["c", "b", "a"], actions: ["close"])
        #expect(state.rowID == "b")
        #expect(state.actionID == "close")
        state.reconcile(["c", "a"], actions: [])
        #expect(state.rowID == "a")
        #expect(state.actionID == nil)
        state.reconcile([], actions: [])
        #expect(state.rowID == nil)
        state.moveRow(-1)
        state.moveAction(1, actions: [])
        #expect(state.actionID == nil)
        state.reconcile(["new"], actions: [])
        #expect(state.rowID == "new")
    }
}
