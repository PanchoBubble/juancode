import Testing
@testable import JuancodeCore

/// ⌃ ⌃ toggles vim sidebar nav; ⌃-chords must never trip it.
@Suite struct ModifierDoubleTapTests {
    private func tap(_ d: inout ModifierDoubleTap, at t: Double) -> Bool {
        _ = d.flagsChanged(onlyTarget: true, none: false, at: t)
        return d.flagsChanged(onlyTarget: false, none: true, at: t + 0.05)
    }

    @Test func twoQuickTapsFire() {
        var d = ModifierDoubleTap()
        #expect(!tap(&d, at: 0))
        #expect(tap(&d, at: 0.2))
    }

    @Test func slowTapsDoNot() {
        var d = ModifierDoubleTap()
        #expect(!tap(&d, at: 0))
        #expect(!tap(&d, at: 1))
        // …but the slow one starts a fresh run.
        #expect(tap(&d, at: 1.2))
    }

    @Test func aThirdTapStartsOver() {
        var d = ModifierDoubleTap()
        _ = tap(&d, at: 0)
        #expect(tap(&d, at: 0.2))
        #expect(!tap(&d, at: 0.4))
    }

    @Test func aChordInBetweenCancels() {
        var d = ModifierDoubleTap()
        _ = tap(&d, at: 0)
        _ = d.flagsChanged(onlyTarget: true, none: false, at: 0.1)
        d.keyDown() // ⌃C
        #expect(!d.flagsChanged(onlyTarget: false, none: true, at: 0.15))
        #expect(!tap(&d, at: 0.2))
    }

    @Test func anotherModifierCancels() {
        var d = ModifierDoubleTap()
        _ = tap(&d, at: 0)
        _ = d.flagsChanged(onlyTarget: true, none: false, at: 0.1)
        #expect(!d.flagsChanged(onlyTarget: false, none: false, at: 0.12)) // ⌃⇧
        #expect(!d.flagsChanged(onlyTarget: false, none: true, at: 0.15))
    }

    @Test func typingBetweenTapsCancels() {
        var d = ModifierDoubleTap()
        _ = tap(&d, at: 0)
        d.keyDown()
        #expect(!tap(&d, at: 0.2))
    }
}
