import Foundation
import Testing
@testable import JuancodeCore

/// Mirrors apps/server/src/activityDetector.test.ts. The TS suite uses fake
/// timers; we use a short real `settleMs` and poll, since the Swift detector is
/// queue/clock-driven.
///
/// The detector reads a headless `TerminalScreen`, so a turn ends when the CLI
/// *erases* the working footer from the screen (CLIs paint it once and then only
/// animate the digits) — not merely when output goes quiet. Tests therefore feed a
/// realistic clear/erase at turn end.
@Suite struct ActivityDetectorTests {
    /// A turn-end frame: clear the screen + home the cursor, as the CLIs do when
    /// they tear down the working footer and repaint the result/prompt.
    static let clear = "\u{1B}[2J\u{1B}[H"

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(SessionActivity, Bool)] = []
        func record(_ s: SessionActivity, _ n: Bool) { lock.withLock { events.append((s, n)) } }
        var snapshot: [(SessionActivity, Bool)] { lock.withLock { events } }
        var states: [SessionActivity] { snapshot.map(\.0) }
    }

    private func poll(_ timeout: TimeInterval = 1.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func sleepMs(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    @Test func goesBusyOnWorkingIndicator() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("✻ Thinking… (3s · esc to interrupt)")
        await poll { c.snapshot.contains { $0.0 == .busy } }
        #expect(c.states == [.busy])
    }

    /// Real claude positions the footer segments with same-line cursor moves, so the
    /// phrase arrives as e.g. "esc␛[44Gto␛[48Ginterrupt". The grid renders those as
    /// spatial gaps (not glued, not on separate rows), so the footer still matches.
    @Test func goesBusyOnCursorFragmentedIndicator() async {
        let variants = [
            "✻ Thinking… (esc\u{1B}[1;44Hto\u{1B}[1;48Hinterrupt)", // same-row CUP
            "✻ Thinking… (esc\u{1B}[44Gto interrupt)",              // CHA then contiguous
            "✻ Thinking… (esc\u{1B}[40Gto\u{1B}[44Ginterrupt)",     // CHA per segment
        ]
        for v in variants {
            let c = Collector()
            let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
            det.feed(v)
            await poll { c.snapshot.contains { $0.0 == .busy } }
            #expect(c.snapshot.contains { $0.0 == .busy }, "should go busy on: \(v.debugDescription)")
        }
    }

    @Test func settlesToIdleWhenFooterErased() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("✻ Working… (esc to interrupt)")
        det.feed(Self.clear + "Here is the answer.\n") // footer torn down, plain result
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.map { [$0.0.rawValue, "\($0.1)"] }
            == [["busy", "false"], ["idle", "true"]])
    }

    @Test func classifiesOptionMenuAsWaitingInput() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("Running… esc to interrupt")
        det.feed(Self.clear + "Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(c.snapshot.last?.1 == true)
    }

    @Test func ignoresBannerAndTyping() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("Welcome to Claude Code!\n")
        det.feed("> what is 2 + 2")
        await sleepMs(200) // past the settle window
        #expect(c.snapshot.isEmpty)
    }

    /// The headline fix: while the footer is still on screen the session stays busy,
    /// even across a long quiet stretch (slow tool call / model latency). The old
    /// quiet-based detector wrongly settled to idle here.
    @Test func staysBusyWhileFooterVisible() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 80) { c.record($0, $1) }
        det.feed("✻ Working… (esc to interrupt)\n") // footer on its own line
        await sleepMs(150)                            // long quiet pause mid-turn
        det.feed("streaming a token…\n")              // output above the footer
        await sleepMs(150)
        det.feed("more tokens…\n")
        await sleepMs(150)
        #expect(c.states == [.busy]) // never falsely settled
        // Once the footer is erased, it settles.
        det.feed(Self.clear + "Done.\n")
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    /// Safety net: if the footer lingers but the spinner stops emitting, the
    /// watchdog demotes the stuck busy after `watchdogMs`.
    @Test func watchdogDemotesStuckBusy() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60, watchdogMs: 150) { c.record($0, $1) }
        det.feed("✻ Working… (esc to interrupt)") // footer stays, no further output
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.map(\.0) == [.busy, .idle])
        #expect(c.snapshot.last?.1 == true)
    }

    @Test func returnsToIdleOnReset() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("esc to interrupt")
        await poll { c.snapshot.contains { $0.0 == .busy } }
        det.reset()
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
        #expect(c.snapshot.last?.1 == false)
    }
}
