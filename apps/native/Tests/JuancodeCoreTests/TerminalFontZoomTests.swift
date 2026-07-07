import Testing
@testable import JuancodeCore

/// Terminal font-zoom math (juancode-fry): a global level in 1pt steps from the
/// default, applied to Ghostty via incremental binding actions and to SwiftTerm via
/// an absolute point size. These tests pin the clamping and the level→steps mapping.
@Suite struct TerminalFontZoomTests {
    @Test func clampsToBounds() {
        #expect(TerminalFontZoom.clamp(0) == 0)
        #expect(TerminalFontZoom.clamp(TerminalFontZoom.maxLevel + 5) == TerminalFontZoom.maxLevel)
        #expect(TerminalFontZoom.clamp(TerminalFontZoom.minLevel - 5) == TerminalFontZoom.minLevel)
    }

    @Test func zoomInAndOutStepByOneAndSaturate() {
        #expect(TerminalFontZoom.zoomedIn(0) == 1)
        #expect(TerminalFontZoom.zoomedOut(0) == -1)
        // At the ceiling/floor a further press is a no-op (same level → caller emits nothing).
        #expect(TerminalFontZoom.zoomedIn(TerminalFontZoom.maxLevel) == TerminalFontZoom.maxLevel)
        #expect(TerminalFontZoom.zoomedOut(TerminalFontZoom.minLevel) == TerminalFontZoom.minLevel)
    }

    @Test func pointsTrackTheLevelOffsetFromBase() {
        #expect(TerminalFontZoom.points(forLevel: 0, base: 13) == 13)
        #expect(TerminalFontZoom.points(forLevel: 3, base: 13) == 16)
        #expect(TerminalFontZoom.points(forLevel: -2, base: 13) == 11)
        // Out-of-range points are clamped, not extrapolated.
        #expect(TerminalFontZoom.points(forLevel: 999, base: 13)
                == 13 + Double(TerminalFontZoom.maxLevel))
    }

    @Test func bindingStepsEmitsOneActionPerLevelInTheRightDirection() {
        #expect(TerminalFontZoom.bindingSteps(from: 0, to: 0).isEmpty)
        #expect(TerminalFontZoom.bindingSteps(from: 0, to: 3)
                == Array(repeating: TerminalFontZoom.increaseAction, count: 3))
        #expect(TerminalFontZoom.bindingSteps(from: 2, to: -1)
                == Array(repeating: TerminalFontZoom.decreaseAction, count: 3))
    }

    @Test func bindingStepsClampBothEndpointsSoNoRunawaySequence() {
        // A wildly out-of-range applied value still yields a bounded delta.
        let steps = TerminalFontZoom.bindingSteps(from: 9999, to: 0)
        #expect(steps.count == TerminalFontZoom.maxLevel)
        #expect(steps.allSatisfy { $0 == TerminalFontZoom.decreaseAction })
        // Both endpoints clamping to the same bound is a no-op.
        #expect(TerminalFontZoom.bindingSteps(from: 9999, to: 8888).isEmpty)
    }
}
