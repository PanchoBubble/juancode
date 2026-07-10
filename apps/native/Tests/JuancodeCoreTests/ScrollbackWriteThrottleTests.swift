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
        t.didFullFlush() // idle-edge / exit reindex clears it
        #expect(!t.ftsStale)
    }

    @Test func chatteryIdleEdgesWithoutOutputStayClean() {
        var t = ScrollbackWriteThrottle(flushThresholdBytes: 1000)
        t.didFullFlush()
        // Detector flips idle->busy->idle with no output: nothing to reindex.
        #expect(!t.ftsStale)
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
