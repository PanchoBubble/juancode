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

    // ── Structured stream-json signal (juancode-1c9 / doq) ────────────────────

    @Test func goesBusyOnAgentStructuredEventWithNoFooter() async {
        // No "esc to interrupt" text anywhere — the screen path can't see this; the
        // structured pulse is what makes us busy. This is the robustness win.
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feedStructured([.assistant])
        await poll { c.snapshot.contains { $0.0 == .busy } }
        #expect(c.states == [.busy])
    }

    @Test func treatsAgentKindsAsActivity() async {
        for kind in [StructuredEventKind.thinking, .toolUse, .toolResult] {
            let c = Collector()
            let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
            det.feedStructured([kind])
            await poll { c.snapshot.contains { $0.0 == .busy } }
            #expect(c.snapshot.contains { $0.0 == .busy }, "should go busy on: \(kind)")
        }
    }

    @Test func doesNotGoBusyOnLoneUserEvent() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feedStructured([.user]) // the user's own prompt landing — not agent work
        await sleepMs(200)
        #expect(c.snapshot.isEmpty)
    }

    @Test func settlesStructuredTurnToIdleWhenQuiet() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feedStructured([.assistant])
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.map { [$0.0.rawValue, "\($0.1)"] }
            == [["busy", "false"], ["idle", "true"]])
    }

    @Test func settlesStructuredTurnToWaitingInputWhenScreenShowsPrompt() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feedStructured([.toolUse])
        // The permission prompt is rendered to the screen but not (yet) the transcript.
        det.feed("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(c.snapshot.last?.1 == true)
    }

    /// The transcript says the agent stopped; the CLI just hasn't erased the footer
    /// yet. The structured path must not pin us busy on a stale footer.
    @Test func structuredTurnSettlesOnQuietDespiteLingeringFooter() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("✻ Working… (esc to interrupt)")   // footer visible
        det.feedStructured([.assistant])             // upgrades the turn to structured
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    @Test func structuredPulseReArmsSettleWindow() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 120) { c.record($0, $1) }
        det.feedStructured([.toolUse])
        await sleepMs(60)                 // under settleMs
        det.feedStructured([.toolResult]) // re-arms before settle fires
        await sleepMs(60)
        #expect(c.states == [.busy])      // never settled early
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    // ── open tool_use hold (juancode-yno) ──────────────────────────────────────

    /// The headline fix: a tool_use with no tool_result yet (slow tool, delegated
    /// subagent) goes transcript- and screen-quiet for minutes; the watchdog must
    /// not demote busy while the call is still in flight.
    @Test func openToolUseHoldsBusyAcrossWatchdog() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: ["t1"]))
        await sleepMs(400) // several watchdog windows of total silence
        #expect(c.states == [.busy]) // never demoted
    }

    @Test func toolResultReleasesHoldAndSettles() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: ["t1"]))
        await sleepMs(250) // held busy past the watchdog
        #expect(c.states == [.busy])
        det.feedStructured(StructuredEventBatch(kinds: [.toolResult], resolvedToolUseIds: ["t1"]))
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.states == [.busy, .idle])
        #expect(c.snapshot.last?.1 == true)
    }

    @Test func holdWaitsForEveryPendingToolUse() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse, .toolUse], openedToolUseIds: ["t1", "t2"]))
        det.feedStructured(StructuredEventBatch(kinds: [.toolResult], resolvedToolUseIds: ["t1"]))
        await sleepMs(250) // t2 still open — held
        #expect(c.states == [.busy])
        det.feedStructured(StructuredEventBatch(kinds: [.toolResult], resolvedToolUseIds: ["t2"]))
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    @Test func resetClearsPendingToolUses() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: ["t1"]))
        await poll { c.snapshot.contains { $0.0 == .busy } }
        det.reset()
        await poll { c.snapshot.last?.0 == .idle }
        // A fresh turn with no ids must settle normally — t1 must not linger.
        det.feedStructured([.assistant])
        await poll { c.snapshot.last?.0 == .busy }
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    /// A crashed tool never writes its tool_result; past the cap the hold releases
    /// and normal settle classification demotes.
    @Test func holdCapAllowsDemotionAfterExpiry() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100, toolHoldCapMs: 200) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: ["t1"]))
        await sleepMs(120) // inside the cap — still held
        #expect(c.states == [.busy])
        await poll(2.0) { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    /// A tool_use is written to the transcript *before* its permission menu is
    /// answered, so a visible prompt must beat the hold — the user needs the ping.
    @Test func promptBeatsOpenToolUseHold() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 40, watchdogMs: 100) { c.record($0, $1) }
        det.feedStructured(StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: ["t1"]))
        det.feed("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(c.snapshot.last?.1 == true)
    }

    @Test func batchHasAgentActivityDistinguishesUser() {
        #expect(batchHasAgentActivity([.user, .assistant]))
        #expect(batchHasAgentActivity([.toolUse]))
        #expect(!batchHasAgentActivity([]))
        #expect(!batchHasAgentActivity([.user]))
    }

    // ── idle → waitingInput without a preceding turn (juancode-8w5) ───────────

    /// Push `text` into the bottom region by prefixing enough blank rows.
    private func atBottom(_ text: String) -> String { Self.clear + String(repeating: "\n", count: 30) + text }

    @Test func promotesIdleToWaitingOnFolderTrustDialog() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(atBottom("Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit\n"))
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(c.snapshot.last?.1 == true)
        #expect(det.lastPromptMatch == "select-cursor")
    }

    @Test func promotesIdleToWaitingOnYesNoPrompt() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(atBottom("Overwrite the file? (y/n)"))
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(det.lastPromptMatch == "yn-paren")
    }

    @Test func ignoresStartupBannerNoPrompt() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(Self.clear + "✻ Welcome to Claude Code!\n\n  /help for help\n\n> ")
        await sleepMs(200)
        #expect(c.snapshot.isEmpty)
        #expect(det.activity == .idle)
    }

    @Test func doesNotTriggerOnScrolledUpDoYouWant() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        // Prose at the top; the bottom region (where a live prompt would be) is blank.
        det.feed(Self.clear + "Earlier I asked: Do you want to refactor this?\n" + String(repeating: "\n", count: 35))
        await sleepMs(200)
        #expect(c.snapshot.isEmpty)
        #expect(det.activity == .idle)
    }

    @Test func clearsWaitingBackToIdleWhenAnswered() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(atBottom("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"))
        await poll { c.snapshot.last?.0 == .waitingInput }
        // The menu is torn down and replaced with a plain result — no marker left.
        det.feed(Self.clear + "Done.\n")
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
        #expect(c.snapshot.last?.1 == false)
    }

    @Test func noFlickerDuringOrdinaryStreaming() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        // Idle output that contains a '?' but no prompt in the bottom region.
        det.feed(Self.clear + "The answer to your question is 42.\n" + String(repeating: "\n", count: 35))
        await sleepMs(200)
        #expect(c.snapshot.isEmpty)
    }

    // ── multibyte UTF-8 split across chunk boundaries (juancode-5qw.6) ──────────

    /// The working footer opens with a 3-byte glyph (✻) and a 3-byte ellipsis (…).
    /// A pty read can split a chunk anywhere, including mid-glyph. Feeding the raw
    /// bytes split inside the leading "✻" must still go busy — the incremental
    /// decoder carries the partial sequence so the screen reconstructs it intact,
    /// exactly as the whole-sequence feed does.
    @Test func goesBusyWhenMultibyteFooterSplitAcrossChunks() async {
        let footer = "✻ Working… (esc to interrupt)"
        let bytes = Array(footer.utf8)
        // Split one byte into the first glyph (its lead byte alone in chunk 1).
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(Array(bytes[0..<1]))
        det.feed(Array(bytes[1...]))
        await poll { c.snapshot.contains { $0.0 == .busy } }
        #expect(c.snapshot.contains { $0.0 == .busy }, "split-glyph footer should still go busy")
        // Identical outcome to feeding the whole sequence in one chunk.
        let whole = Collector()
        let detWhole = ActivityDetector(settleMs: 60) { whole.record($0, $1) }
        detWhole.feed(bytes)
        await poll { whole.snapshot.contains { $0.0 == .busy } }
        #expect(whole.states == c.states, "split feed must match whole-sequence detection")
    }

    /// The `select-cursor` prompt marker (❯, 3 bytes) is the CLI's own menu UI. If a
    /// pty read splits it across two chunks, a naive per-chunk `String(decoding:)`
    /// would decode replacement characters on both sides and the prompt would never
    /// match. The carried-tail decoder keeps it intact, so waitingInput still fires.
    @Test func detectsPromptWhenMultibyteCursorSplitAcrossChunks() async {
        let head = Self.clear + String(repeating: "\n", count: 30) + "Do you want to proceed?\n "
        let cursor = Array("❯".utf8) // [0xE2, 0x9D, 0xAF]
        let tail = " 1. Yes\n   2. No\n"
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed(Array(head.utf8) + [cursor[0]])          // splits mid-glyph
        det.feed(Array(cursor[1...]) + Array(tail.utf8))
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(det.lastPromptMatch == "select-cursor")
    }

    @Test func utf8BoundaryCarriesIncompleteTail() {
        // Complete ASCII: nothing carried.
        #expect(Utf8Boundary.completePrefixLength(Array("abc".utf8)) == 3)
        // Complete multibyte: nothing carried.
        let full = Array("a✻".utf8) // 1 + 3 bytes
        #expect(Utf8Boundary.completePrefixLength(full) == full.count)
        // Trailing lead byte of a 3-byte glyph, alone: carry 1.
        #expect(Utf8Boundary.completePrefixLength([0x61, 0xE2]) == 1)
        // Trailing lead + one continuation of a 3-byte glyph: carry 2.
        #expect(Utf8Boundary.completePrefixLength([0x61, 0xE2, 0x9C]) == 1)
        // A 4-byte emoji missing its last byte: carry 3.
        let emoji = Array("😀".utf8) // [0xF0,0x9F,0x98,0x80]
        #expect(Utf8Boundary.completePrefixLength(Array(emoji[0..<3])) == 0)
        // Stray continuation byte with no lead: malformed, left in the prefix.
        #expect(Utf8Boundary.completePrefixLength([0x80]) == 1)
        #expect(Utf8Boundary.completePrefixLength([]) == 0)
    }
}
