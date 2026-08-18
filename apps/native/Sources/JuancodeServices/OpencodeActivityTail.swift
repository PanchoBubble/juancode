import Foundation
import JuancodeCore

/// The opencode counterpart of `TranscriptActivityTail`: feeds structured activity
/// pulses into the `ActivityDetector` (juancode-1c9) so busy/idle doesn't depend on
/// TUI wording. Same contract — `start()`, `stop()`, one `(batch, reset)` listener —
/// but the source is opencode's SQLite `part` table rather than an append-only JSONL
/// file, so the cursor is a `time_updated` watermark instead of a byte offset.
///
/// A tool part is REWRITTEN in place as it runs (`pending` → `running` → `completed`),
/// which is what makes the watermark inclusive: rows at exactly the watermark are
/// re-read on the next poll so a status change is seen, and the ids already emitted at
/// that millisecond are remembered so nothing is emitted twice.
public final class OpencodeActivityTail: @unchecked Sendable {
    public typealias BatchListener = @Sendable (_ batch: StructuredEventBatch, _ reset: Bool) -> Void

    /// A getter, not a value: opencode's session id lands shortly after spawn.
    private let getCliSessionId: @Sendable () -> String?
    private let listener: BatchListener
    private let db: String
    private let pollMs: Int

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "juancode.opencodetail")
    private var timer: DispatchSourceTimer?
    /// Rows are read at/after this `time_updated`; nil until the backlog is skipped.
    private var cursorMs: Int?
    /// `part id + state` already emitted at exactly `cursorMs` (the only rows the next
    /// inclusive poll can hand us again).
    private var emittedAtCursor: Set<String> = []
    private var sentBacklog = false
    private var polling = false

    public init(
        cliSessionId: @escaping @Sendable () -> String?,
        db: String = OpencodeStore.defaultPath,
        pollMs: Int = 1000,
        listener: @escaping BatchListener
    ) {
        self.getCliSessionId = cliSessionId
        self.db = db
        self.pollMs = pollMs
        self.listener = listener
    }

    /// Poll once immediately, then on an interval until `stop`.
    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(pollMs))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        let t: DispatchSourceTimer? = lock.withLock {
            let cur = timer
            timer = nil
            return cur
        }
        t?.cancel()
    }

    /// Read the parts touched since the watermark and emit their kinds. Serialized
    /// against itself so a slow read can't overlap the next tick.
    public func poll() {
        let claimed = lock.withLock { () -> Bool in
            if polling { return false }
            polling = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { polling = false } }

        guard let sessionId = getCliSessionId() else { return } // id not discovered yet

        // First sight: don't load a resumed conversation's whole history just to throw
        // it away (the session skips `reset` batches). Take the watermark straight from
        // the table and report an empty backlog.
        guard let cursor = cursorMs else {
            let watermark = OpencodeStore.latestPartMs(sessionId: sessionId, db: db) ?? 0
            cursorMs = watermark
            // The watermark itself is re-read on every later poll (a tool part can be
            // rewritten in place at that millisecond), so the rows already sitting there
            // count as emitted — otherwise the next poll would replay the tail of the
            // backlog as if it were live.
            emittedAtCursor = Set(
                OpencodeStore.parts(sessionId: sessionId, sinceMs: watermark, db: db)
                    .map { "\($0.id)|\(opencodePartBatch($0).signature)" })
            if !sentBacklog {
                sentBacklog = true
                listener(StructuredEventBatch(kinds: []), true)
            }
            return
        }

        let rows = OpencodeStore.parts(sessionId: sessionId, sinceMs: cursor, db: db)
        guard !rows.isEmpty else { return }

        var batch = StructuredEventBatch(kinds: [])
        let newCursor = rows.map(\.updatedMs).max() ?? cursor
        var emittedAtNewCursor: Set<String> = []
        for part in rows {
            let one = opencodePartBatch(part)
            let key = "\(part.id)|\(one.signature)"
            let alreadySeen = part.updatedMs == cursor && emittedAtCursor.contains(key)
            if part.updatedMs == newCursor { emittedAtNewCursor.insert(key) }
            if alreadySeen { continue }
            batch.kinds.append(contentsOf: one.batch.kinds)
            batch.openedToolUseIds.append(contentsOf: one.batch.openedToolUseIds)
            batch.resolvedToolUseIds.append(contentsOf: one.batch.resolvedToolUseIds)
        }
        // Rows below the new watermark can never come back, so only the ids AT it need
        // remembering — the set stays as small as one millisecond of writes.
        cursorMs = newCursor
        emittedAtCursor = newCursor == cursor
            ? emittedAtCursor.union(emittedAtNewCursor)
            : emittedAtNewCursor

        if !batch.kinds.isEmpty { listener(batch, false) }
    }
}

/// A part's structured events plus a signature identifying the *state* they came from,
/// so the same part emitted at a new status counts as new activity.
struct OpencodePartEvents {
    let batch: StructuredEventBatch
    let signature: String
}

/// Map one opencode message part to the structured events it carries — the opencode
/// analogue of `claudeRecordBatch` / `codexRecordBatch`.
///
///   - a `text` part is the user's message or the agent's, by its message's role
///   - a `reasoning` part is thinking
///   - a `tool` part opens on `pending`/`running` and resolves on `completed`/`error`,
///     paired by `callID` so the detector can hold busy across a long tool call
func opencodePartBatch(_ part: OpencodeStore.PartRow) -> OpencodePartEvents {
    let type = part.data["type"] as? String ?? ""
    switch type {
    case "text":
        let text = part.data["text"] as? String ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return OpencodePartEvents(batch: StructuredEventBatch(kinds: []), signature: type)
        }
        let kind: StructuredEventKind = part.role == "user" ? .user : .assistant
        return OpencodePartEvents(
            batch: StructuredEventBatch(kinds: [kind]), signature: "\(type):\(part.role)")
    case "reasoning":
        let text = part.data["text"] as? String ?? ""
        let kinds: [StructuredEventKind] =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.thinking]
        return OpencodePartEvents(batch: StructuredEventBatch(kinds: kinds), signature: type)
    case "tool":
        let callId = part.data["callID"] as? String
        let state = part.data["state"] as? [String: Any]
        let status = state?["status"] as? String ?? "pending"
        let signature = "\(type):\(status)"
        if status == "completed" || status == "error" {
            return OpencodePartEvents(
                batch: StructuredEventBatch(
                    kinds: [.toolResult], resolvedToolUseIds: callId.map { [$0] } ?? []),
                signature: signature)
        }
        return OpencodePartEvents(
            batch: StructuredEventBatch(
                kinds: [.toolUse], openedToolUseIds: callId.map { [$0] } ?? []),
            signature: signature)
    default:
        // step-start / step-finish / patch / file / compaction — no activity of their own.
        return OpencodePartEvents(batch: StructuredEventBatch(kinds: []), signature: type)
    }
}
