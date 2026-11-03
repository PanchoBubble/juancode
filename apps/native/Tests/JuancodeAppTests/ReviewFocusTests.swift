import AppKit
import Testing
@testable import JuancodeApp

@Suite @MainActor struct ReviewFocusTests {
    @Test func coveredReviewCannotReclaimTerminalFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let catcher = ReviewKeyCatcherView()
        let terminal = NSTextView()
        window.contentView?.addSubview(catcher)
        window.contentView?.addSubview(terminal)
        defer { window.contentView = nil }

        #expect(ReviewKeyCatcherView.mounted(in: window) === catcher)
        #expect(window.makeFirstResponder(catcher))
        catcher.enabled = false
        #expect(window.makeFirstResponder(terminal))
        #expect(ReviewKeyCatcherView.mounted(in: window) == nil)
        #expect(!catcher.acceptsFirstResponder)
        #expect(window.firstResponder === terminal)

        catcher.enabled = true
        #expect(ReviewKeyCatcherView.mounted(in: window) === catcher)
        #expect(window.makeFirstResponder(catcher))
        #expect(window.firstResponder === catcher)
    }

    @Test func coveredReviewDoesNotHandleTyping() throws {
        let catcher = ReviewKeyCatcherView()
        var keys: [ReviewKey] = []
        catcher.onKey = { keys.append($0); return true }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "j",
            charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        catcher.enabled = false
        catcher.keyDown(with: event)
        #expect(keys.isEmpty)
        catcher.enabled = true
        catcher.keyDown(with: event)
        #expect(keys == [.char("j")])
    }
}
