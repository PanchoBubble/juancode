import Foundation

/// Write-amplification throttle for a session's scrollback persistence
/// (juancode-5qw.1).
///
/// A busy session used to serialize its full (capped, up to 256KiB) scrollback ring
/// and delete+reinsert its FTS5 row on every 2s output debounce — the dominant
/// persistence hot path (a full serialize + tokenize of the ring per busy session
/// per debounce tick). This concentrates the expensive *full* write (scrollback
/// column + FTS reindex) onto the busy->idle edge / exit, where search actually
/// needs to catch up, and demotes the periodic crash-safety flush to a cheap
/// scrollback-only column write that skips the FTS tokenize entirely.
///
/// Pure value type with no locking of its own so the policy is unit-testable in
/// isolation; `Session` owns one instance and mutates it under its own `lock`.
struct ScrollbackWriteThrottle {
    /// New output bytes that force a crash-safety (scrollback-only) flush mid-burst,
    /// so a session streaming continuously (no idle gap to trip the trailing
    /// debounce) still persists recent output. Bounds worst-case crash loss to
    /// roughly this many bytes.
    let flushThresholdBytes: Int

    /// Floor on the gap between two full flushes (FTS reindex) of one session. An
    /// agent flips busy->idle several times a minute mid-turn (one edge per tool
    /// call), and each edge used to delete + re-tokenize the whole 256KiB ring —
    /// measured at ~83% saturation of the shared GRDB write queue with 5 live
    /// sessions (juancode-5bwj). Search freshness within a minute is plenty, so the
    /// edge now *requests* a reindex and this decides whether it runs or waits.
    let ftsMinIntervalMs: Int

    /// Bytes appended since the last scrollback-column write.
    private var pendingBytes = 0
    /// True once output has been appended that the FTS index hasn't seen yet. A
    /// scrollback-only flush does NOT clear this (it skips FTS); only a full flush
    /// does — so the busy->idle edge knows whether a reindex is worth doing.
    private var dirtySinceFts = false
    /// When the last full flush ran, or nil if none has yet — the first reindex of a
    /// session is always allowed through so a short-lived session still gets indexed.
    private var lastFullFlushMs: Int?

    init(flushThresholdBytes: Int, ftsMinIntervalMs: Int = 60_000) {
        self.flushThresholdBytes = max(1, flushThresholdBytes)
        self.ftsMinIntervalMs = max(0, ftsMinIntervalMs)
    }

    /// Record appended output. Returns `true` when enough has accumulated to warrant
    /// an immediate scrollback-only flush.
    mutating func onOutput(_ byteCount: Int) -> Bool {
        pendingBytes += byteCount
        dirtySinceFts = true
        if pendingBytes >= flushThresholdBytes {
            pendingBytes = 0
            return true
        }
        return false
    }

    /// A scrollback-only flush (trailing debounce or byte-threshold) happened: the
    /// column is current but the FTS index is still behind.
    mutating func didFlushScrollback() {
        pendingBytes = 0
    }

    /// A full flush (scrollback column + FTS reindex) happened: everything is current.
    /// `nowMs` opens the rate-limit window for the next one.
    mutating func didFullFlush(nowMs: Int) {
        pendingBytes = 0
        dirtySinceFts = false
        lastFullFlushMs = nowMs
    }

    /// Whether the FTS index lags the appended scrollback, i.e. an idle-edge / exit
    /// full flush would actually surface new content. A chattery activity detector
    /// that flips idle->busy->idle without output in between reads `false` here, so
    /// it can't spam full writes.
    var ftsStale: Bool { dirtySinceFts }

    /// The verdict for a requested full flush at `nowMs`.
    enum FullFlushDecision: Equatable {
        /// Nothing new since the last reindex — drop the request.
        case skip
        /// Run it now.
        case now
        /// Rate-limited: run it in this many ms, once the window opens.
        case after(ms: Int)
    }

    /// Decide what to do with a full-flush request (a busy->idle turn edge). A
    /// `.after` verdict must be honoured by arming a deferred flush, not dropped —
    /// otherwise a session that goes idle and stays idle would never index its last
    /// turn. Pure: reads the clock the caller passes and mutates nothing.
    func fullFlushDecision(nowMs: Int) -> FullFlushDecision {
        guard dirtySinceFts else { return .skip }
        guard let last = lastFullFlushMs else { return .now }
        let elapsed = nowMs - last
        // A clock that jumped backwards (or an out-of-order caller) shouldn't stall
        // indexing until it catches up — treat any non-positive gap as "due now".
        guard elapsed >= 0 else { return .now }
        return elapsed >= ftsMinIntervalMs ? .now : .after(ms: ftsMinIntervalMs - elapsed)
    }
}
