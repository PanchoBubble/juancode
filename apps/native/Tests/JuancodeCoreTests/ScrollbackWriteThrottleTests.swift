import Testing
@testable import JuancodeCore

/// The write-amplification policy behind delta scrollback persistence (juancode-5qw.1).
/// Deterministic, no pty / timing — asserts a heavy burst does far fewer full
/// (FTS-reindexing) writes than the naive per-2s-debounce count.
@Suite struct ScrollbackWriteThrottleTests {
    @Test func flushesOncePerThresholdOfAccumulatedBytes() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 100)
        var flushes = 0
        // 1000 bytes delivered in 10-byte chunks → one flush per 100 bytes.
        for _ in 0..<100 where t.onOutput(10) { flushes += 1 }
        #expect(flushes == 10)
    }

    @Test func aSingleLargeChunkTripsAtMostOneFlush() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 100)
        let first = t.onOutput(10_000) // one flush, remainder does not carry a phantom second
        let second = t.onOutput(1)
        #expect(first)
        #expect(!second)
    }

    @Test func crashSafetyFlushLeavesFtsStaleUntilFullFlush() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000)
        #expect(!t.ftsStale)
        _ = t.onOutput(10)
        #expect(t.ftsStale) // output pending an index
        t.didFlushScrollback() // crash-safety flush skips FTS → still stale
        #expect(t.ftsStale)
        t.didFullFlush(nowMs: 0) // idle-edge / exit reindex clears it
        #expect(!t.ftsStale)
    }

    @Test func chatteryIdleEdgesWithoutOutputStayClean() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000)
        t.didFullFlush(nowMs: 0)
        // Detector flips idle->busy->idle with no output: nothing to reindex.
        #expect(!t.ftsStale)
    }

    // MARK: - full-flush rate limit (juancode-5bwj)

    @Test func firstFullFlushIsAllowedImmediately() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000, ftsMinIntervalMs: 60_000)
        _ = t.onOutput(10)
        // A short-lived session must index even though no window has opened yet.
        #expect(t.fullFlushDecision(nowMs: 5) == .now)
    }

    @Test func cleanSessionSkipsRatherThanDefers() {
        let t = ScrollbackWriteThrottle(flushThresholdBytes: 1000, ftsMinIntervalMs: 60_000)
        // No output at all → nothing owed, and nothing to arm.
        #expect(t.fullFlushDecision(nowMs: 1_000) == .skip)
    }

    @Test func edgesInsideTheWindowDeferByTheRemainder() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000, ftsMinIntervalMs: 60_000)
        _ = t.onOutput(10)
        t.didFullFlush(nowMs: 10_000)
        _ = t.onOutput(10)
        // 20s after the last reindex: 40s of the window left.
        #expect(t.fullFlushDecision(nowMs: 30_000) == .after(ms: 40_000))
        // On the boundary it's due.
        #expect(t.fullFlushDecision(nowMs: 70_000) == .now)
        #expect(t.fullFlushDecision(nowMs: 90_000) == .now)
    }

    @Test func aBackwardsClockDoesNotStallIndexing() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000, ftsMinIntervalMs: 60_000)
        _ = t.onOutput(10)
        t.didFullFlush(nowMs: 100_000)
        _ = t.onOutput(10)
        // Clock jumped back (NTP correction): don't wait for it to catch up.
        #expect(t.fullFlushDecision(nowMs: 50_000) == .now)
    }

    /// The measured regression (juancode-5bwj): an agent crossing the busy->idle edge
    /// once per tool call drove one full 256KiB reindex per edge — 0.26/sec across 5
    /// live sessions, saturating the shared GRDB write queue. The rate limit collapses
    /// a minute of edges into a single reindex.
    @Test func aMinuteOfChatteryTurnEdgesCollapsesToOneReindex() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 128 * 1024, ftsMinIntervalMs: 60_000)
        var reindexes = 0
        // 60s of output with a turn edge every 2s: 30 requests.
        for tick in stride(from: 0, to: 60_000, by: 2_000) {
            _ = t.onOutput(4 * 1024)
            if t.fullFlushDecision(nowMs: tick) == .now {
                reindexes += 1
                t.didFullFlush(nowMs: tick)
            }
        }
        // Only the first (no window open yet) runs; the other 29 defer onto it.
        #expect(reindexes == 1)
        #expect(t.ftsStale) // still owed, and the deferred flush will clear it
    }

    /// Micro-benchmark: ~3 MiB streamed in 4 KiB chunks. The old policy rewrote the
    /// full ring + FTS row on every 2s debounce (~30 full writes over a ~60s burst);
    /// the throttle does zero full writes mid-burst (FTS deferred to the idle edge)
    /// and only bounded, FTS-free scrollback flushes.
    @Test func heavyBurstDoesFarFewerFullWritesThanNaivePer2s() {
        let threshold = 128 * 1024
        var t = ScrollbackWriteThrottle(flushThresholdBytes: threshold)
        let chunk = 4 * 1024
        let total = 3 * 1024 * 1024
        var scrollbackOnlyFlushes = 0
        for _ in 0..<(total / chunk) where t.onOutput(chunk) { scrollbackOnlyFlushes += 1 }

        // Bounded, cheap (no FTS) flushes: one per threshold of new bytes.
        #expect(scrollbackOnlyFlushes == total / threshold) // 24
        // Full FTS reindexes during the burst: zero — the throttle never signals one;
        // they happen only on the closing idle edge / exit. That's the order-of-
        // magnitude drop vs a naive ~30 full-ring serialize+tokenize writes.
        #expect(t.ftsStale) // exactly one full flush still owed, at the idle edge
    }
}
