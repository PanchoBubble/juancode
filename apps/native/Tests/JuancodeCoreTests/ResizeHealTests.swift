import Foundation
import Testing
@testable import JuancodeCore

/// juancode-8llo: the post-resize heal decision both terminal backends share.
@Suite struct ResizeHealPolicyTests {
    @Test func idleResizeRepaintsWithoutSigwinch() {
        var p = ResizeHealPolicy()
        p.arm()
        let action = p.fire()
        // Nothing streamed: the CLI already repainted for its own SIGWINCH, so a flap
        // would only make it re-lay-out for nothing. The screen repaint still runs.
        #expect(action == ResizeHealAction(repaint: true, sigwinch: false))
    }

    @Test func streamingResizeAlsoForcesSigwinch() {
        var p = ResizeHealPolicy()
        p.arm()
        let noted = p.noteOutput()
        #expect(noted)
        let action = p.fire()
        #expect(action == ResizeHealAction(repaint: true, sigwinch: true))
    }

    /// The streaming signal has to survive a whole drag: re-arming on every
    /// intermediate resize must not forget that the CLI was mid-stream.
    @Test func rearmingKeepsTheStreamingSignal() {
        var p = ResizeHealPolicy()
        p.arm()
        p.noteOutput()
        p.arm() // another resize in the same gesture
        p.arm()
        #expect(p.sawStream)
        #expect(p.fire().sigwinch)
    }

    /// `fire` disarms, so the redraw bytes the heal provokes can't arm the next heal
    /// into a loop.
    @Test func fireDisarmsSoTheHealCantLoop() {
        var p = ResizeHealPolicy()
        p.arm()
        p.noteOutput()
        _ = p.fire()
        #expect(!p.armed)
        let notedAfterFire = p.noteOutput() // the repaint's own output is ignored
        #expect(!notedAfterFire)
        #expect(!p.fire().sigwinch)
    }

    @Test func outputWithoutAResizeIsIgnored() {
        var p = ResizeHealPolicy()
        let noted = p.noteOutput()
        #expect(!noted)
        #expect(!p.sawStream)
    }

    @Test func disarmDropsAPendingHeal() {
        var p = ResizeHealPolicy()
        p.arm()
        p.noteOutput()
        p.disarm()
        #expect(!p.armed)
        #expect(!p.sawStream)
    }

    /// The timer wrapper the panes own: `onQuiet` fires once, on the main queue, with
    /// the policy's action.
    @Test @MainActor func timerFiresOnceOutputGoesQuiet() async {
        let seen = Box()
        let heal = TerminalResizeHeal(quietMs: 60) { action in seen.set(action) }
        heal.arm()
        heal.noteOutput()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(seen.value == ResizeHealAction(repaint: true, sigwinch: true))
    }

    @Test @MainActor func disarmedTimerNeverFires() async {
        let seen = Box()
        let heal = TerminalResizeHeal(quietMs: 60) { action in seen.set(action) }
        heal.arm()
        heal.disarm()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(seen.value == nil)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ResizeHealAction?
        func set(_ a: ResizeHealAction) { lock.withLock { stored = a } }
        var value: ResizeHealAction? { lock.withLock { stored } }
    }
}
