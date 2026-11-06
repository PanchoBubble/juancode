import AppKit
import Testing
@testable import JuancodeApp

@Suite struct PaneFocusNavigationTests {
    @Test func tmuxDirectionsAndModifiedTyping() {
        for (vim, arrow, direction) in [(UInt16(4), UInt16(123), PaneFocusDirection.left),
                                       (38, 125, .down), (40, 126, .up), (37, 124, .right)] {
            #expect(PaneFocusDirection.matching(keyCode: vim, modifiers: .control) == direction)
            #expect(PaneFocusDirection.matching(keyCode: arrow, modifiers: .option) == direction)
            #expect(PaneFocusDirection.matching(keyCode: vim, modifiers: []) == nil)
            #expect(PaneFocusDirection.matching(keyCode: vim, modifiers: [.command, .control]) == nil)
            #expect(PaneFocusDirection.matching(keyCode: vim, modifiers: [.shift, .control]) == nil)
            #expect(PaneFocusDirection.matching(keyCode: arrow, modifiers: [.shift, .option]) == nil)
        }
        // Existing Oracle and terminal-refresh bindings retain ownership.
        #expect(PaneFocusDirection.matching(keyCode: 49, modifiers: .control) == nil)
        #expect(PaneFocusDirection.matching(keyCode: 6, modifiers: .control) == nil)
    }

    @Test func reviewsAndTextEditorsKeepTheirInput() {
        for key: UInt16 in [4, 38, 40, 37] {
            #expect(PaneFocusDirection.matching(keyCode: key, modifiers: .control, reviewActive: true) == nil)
            #expect(PaneFocusDirection.matching(keyCode: key, modifiers: .control, editingText: true) == nil)
            #expect(PaneFocusDirection.matching(keyCode: key, modifiers: .control, editorFocused: true) == nil)
        }
        for key: UInt16 in [123, 125, 126, 124] {
            #expect(PaneFocusDirection.matching(keyCode: key, modifiers: .option, reviewActive: true) == nil)
            #expect(PaneFocusDirection.matching(keyCode: key, modifiers: .option, editingText: true) == nil)
        }
    }
}
