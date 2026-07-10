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

    /// Bytes appended since the last scrollback-column write.
    private var pendingBytes = 0
    /// True once output has been appended that the FTS index hasn't seen yet. A
    /// scrollback-only flush does NOT clear this (it skips FTS); only a full flush
    /// does — so the busy->idle edge knows whether a reindex is worth doing.
    private var dirtySinceFts = false

    init(flushThresholdBytes: Int) {
        self.flushThresholdBytes = max(1, flushThresholdBytes)
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
    mutating func didFullFlush() {
        pendingBytes = 0
        dirtySinceFts = false
    }

    /// Whether the FTS index lags the appended scrollback, i.e. an idle-edge / exit
    /// full flush would actually surface new content. A chattery activity detector
    /// that flips idle->busy->idle without output in between reads `false` here, so
    /// it can't spam full writes.
    var ftsStale: Bool { dirtySinceFts }
}
