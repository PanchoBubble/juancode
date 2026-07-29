import Foundation

/// Incremental JSONL transcript reading (juancode-dfhg).
///
/// The title/usage poll runs every 4s for every live session. It used to hand each
/// pass to `forEachRecord`, which reads the WHOLE transcript into memory, splits it,
/// and `JSONSerialization`-parses every line. A mature Claude transcript is tens of
/// MB, so a handful of live sessions meant hundreds of MB of parsing every 4s —
/// enough to saturate cores and starve the main thread, which is what made typing
/// lag once several sessions were running.
///
/// A transcript is append-only, so a poll only needs the bytes written since the
/// last one. `TranscriptReader` remembers a byte offset per (namespace, file) and
/// hands the caller just the new records; `TranscriptChunk` is the pure byte→record
/// parsing underneath it.

/// The outcome of one incremental pass.
public struct TranscriptScan: Sendable, Equatable {
    /// True when this pass read from byte 0 — first sight of the file, or it shrank
    /// (rotated / rewritten) so the remembered offset was meaningless. A caller
    /// holding accumulated state (running token totals, the last title seen) must
    /// discard it and rebuild from this pass's records; see `scan`'s `onStart`.
    public var fromStart: Bool
    /// How many records were handed to the callback.
    public var records: Int
    /// The file couldn't be opened (not written yet, deleted). Nothing was scanned
    /// and no accumulated state should be touched.
    public var missing: Bool

    public init(fromStart: Bool, records: Int, missing: Bool) {
        self.fromStart = fromStart
        self.records = records
        self.missing = missing
    }
}

/// Pure JSONL chunk parsing, so the line/record handling is testable without files.
public enum TranscriptChunk {
    /// Hand every **complete** line in `data` to `onRecord`, returning how many
    /// bytes were consumed (the offset just past the last newline handed over).
    ///
    /// A trailing partial line — a record the CLI is still writing — is deliberately
    /// left unconsumed, so the next pass re-reads it once its newline lands. Blank
    /// and unparseable lines are skipped exactly as the whole-file reader does; a
    /// CRLF line ending is tolerated.
    ///
    /// Returning `false` from `onRecord` stops the walk; the returned count still
    /// includes that record's line, so a resuming caller won't see it again.
    public static func forEachCompleteRecord(
        in data: Data,
        _ onRecord: ([String: Any]) -> Bool?
    ) -> Int {
        var consumed = 0
        var lineStart = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            guard data[i] == 0x0A else {
                i += 1
                continue
            }
            let line = data[lineStart..<i]
            i += 1
            lineStart = i
            consumed = i - data.startIndex
            if let rec = record(from: line), onRecord(rec) == false { return consumed }
        }
        return consumed
    }

    /// Parse one line's bytes into a JSON object, or nil when it is blank or
    /// malformed (tolerated, matching the whole-file reader).
    private static func record(from line: Data) -> [String: Any]? {
        // Strip a CRLF's carriage return, then skip whitespace-only lines.
        let trimmed = line.last == 0x0D ? line.dropLast() : line
        guard trimmed.contains(where: { !isSpace($0) }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed))) as? [String: Any]
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || (b >= 0x09 && b <= 0x0D)
    }
}

/// Remembers how far each consumer has read into each transcript, so a repeating
/// poll parses only what was appended since its last pass.
///
/// `@unchecked Sendable`: the sole mutable field (`offsets`) is only ever touched
/// under `lock`.
public final class TranscriptReader: @unchecked Sendable {
    /// The process-wide reader the title / usage polls share. Independent consumers
    /// of the same file stay separated by `namespace`.
    public static let shared = TranscriptReader()

    private let lock = NSLock()
    private var offsets: [String: UInt64] = [:]

    public init() {}

    /// Hand `onRecord` every record appended to `file` since the last `scan` with
    /// this `namespace`, then remember the new position.
    ///
    /// `namespace` separates consumers that read the same file at their own pace
    /// (the title poll and the usage poll each keep their own offset). `onStart`
    /// fires once, before any record, with whether this pass restarted from the top
    /// — the hook for a caller to load or clear its accumulated state.
    ///
    /// Blocking file IO, like the whole-file reader it replaces.
    @discardableResult
    public func scan(
        file: String,
        namespace: String,
        onStart: ((_ fromStart: Bool) -> Void)? = nil,
        _ onRecord: ([String: Any]) -> Bool?
    ) -> TranscriptScan {
        let key = Self.key(file: file, namespace: namespace)
        guard let handle = FileHandle(forReadingAtPath: file),
              let size = try? handle.seekToEnd() else {
            return TranscriptScan(fromStart: false, records: 0, missing: true)
        }
        defer { try? handle.close() }

        let prior = lock.withLock { offsets[key] }
        var start = prior ?? 0
        var fromStart = prior == nil
        // Shrunk since we last looked: the file was rotated or rewritten, so the
        // remembered offset points into different content — start over.
        if start > size {
            start = 0
            fromStart = true
        }
        // Nothing appended: the steady-state poll, which costs one open + seek.
        if start == size, !fromStart {
            return TranscriptScan(fromStart: false, records: 0, missing: false)
        }

        onStart?(fromStart)
        guard (try? handle.seek(toOffset: start)) != nil else {
            return TranscriptScan(fromStart: fromStart, records: 0, missing: true)
        }
        let data = (try? handle.readToEnd()) ?? Data()
        var count = 0
        let consumed = TranscriptChunk.forEachCompleteRecord(in: data) { rec in
            count += 1
            return onRecord(rec)
        }
        lock.withLock { offsets[key] = start + UInt64(consumed) }
        return TranscriptScan(fromStart: fromStart, records: count, missing: false)
    }

    /// Forget a file's position, so the next `scan` reads it from the top. Used by
    /// tests; a caller that also holds accumulated state must clear that too.
    public func forget(file: String, namespace: String) {
        let key = Self.key(file: file, namespace: namespace)
        lock.withLock { _ = offsets.removeValue(forKey: key) }
    }

    /// NUL joins the two halves so no (namespace, path) pair can collide with
    /// another by concatenation.
    private static func key(file: String, namespace: String) -> String {
        "\(namespace)\u{0}\(file)"
    }
}
