import Foundation
import JuancodeCore

/// Tails a session's stream-json transcript purely to feed structured *activity*
/// pulses into the `ActivityDetector` (juancode-1c9) — the preferred,
/// wording-independent busy/idle signal. Mirrors `apps/server/src/structuredTranscript.ts`
/// (and the kind-mapping in `structuredEvents.ts`), but keeps only the event *kinds*
/// and the `tool_use` ids (opened/resolved, so the detector can hold busy across a
/// long tool call): the native app has no client-facing structured *view*, so the
/// rich text the Node normalizer produces isn't needed here.
///
/// Transcripts only ever grow, so tailing is a byte-offset read: each poll reads the
/// slice from the last offset to EOF, parses the complete lines it finds (a trailing
/// partial line is buffered at the byte level so a multi-byte UTF-8 character split
/// across a read boundary is never mis-decoded), maps each record to its kinds, and
/// emits the batch. The first emission is the full backlog with `reset: true` (which
/// the session skips, so a resumed conversation's replayed turns don't spuriously
/// pulse busy); later emissions carry only newly appended kinds.

/// Locate a session's transcript file from its CLI session id, or nil if not found
/// yet. Mirrors `resolveTranscriptFile` in `structuredTranscript.ts`; reuses the same
/// directory scanning `SessionTitle` uses.
public func resolveTranscriptFile(
    _ provider: ProviderId,
    _ cliSessionId: String,
    _ roots: TitleRoots = TitleRoots()
) async -> String? {
    if provider == .claude {
        return await findByBasename(roots.claudeProjects ?? CLAUDE_PROJECTS, "\(cliSessionId).jsonl")
    }
    // Codex files aren't named by session id, so match the `session_meta` header.
    for file in await codexRolloutFiles(roots.codexSessions ?? CODEX_SESSIONS) {
        var match = false
        await forEachRecord(file) { rec in
            if rec["type"] as? String == "session_meta" {
                let payload = rec["payload"] as? [String: Any]
                match = (payload?["id"] as? String) == cliSessionId
            }
            return false // the header is the first record — only ever check it
        }
        if match { return file }
    }
    return nil
}

/// Flatten a Claude/Codex content value (string, or a list of `{text}` / `{content}`
/// blocks) to plain text. Mirrors `contentToText` in `structuredEvents.ts`; used only
/// to decide whether a Codex `reasoning` record carries a non-empty summary.
private func flattenText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let arr = content as? [Any] {
        return arr.map { el -> String in
            if let s = el as? String { return s }
            if let d = el as? [String: Any] {
                if let t = d["text"] as? String { return t }
                if d["content"] != nil { return flattenText(d["content"]) }
            }
            return ""
        }.joined()
    }
    return ""
}

private func isBlank(_ s: String) -> Bool {
    s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// The structured events a Claude transcript record produces (kinds plus tool ids —
/// mirrors `claudeRecordToEvents`, dropping the text).
private func claudeRecordBatch(_ rec: [String: Any]) -> StructuredEventBatch {
    // Sub-agent (Task tool) turns are logged on a sidechain; skip them like the Node
    // normalizer does — the Task tool_use/result still show on the main thread.
    let empty = StructuredEventBatch(kinds: [])
    if rec["isSidechain"] as? Bool == true { return empty }
    guard let message = rec["message"] as? [String: Any] else { return empty }
    let type = rec["type"] as? String

    if type == "user" {
        if let content = message["content"] as? String {
            return StructuredEventBatch(kinds: isBlank(content) ? [] : [.user])
        }
        if let content = message["content"] as? [Any] {
            var batch = empty
            for block in content {
                guard let b = block as? [String: Any],
                      b["type"] as? String == "tool_result" else { continue }
                batch.kinds.append(.toolResult)
                if let id = b["tool_use_id"] as? String { batch.resolvedToolUseIds.append(id) }
            }
            return batch
        }
        return empty
    }

    if type == "assistant", let content = message["content"] as? [Any] {
        var batch = empty
        for block in content {
            guard let b = block as? [String: Any] else { continue }
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !isBlank(t) { batch.kinds.append(.assistant) }
            case "thinking":
                if let t = b["thinking"] as? String, !isBlank(t) { batch.kinds.append(.thinking) }
            case "tool_use":
                batch.kinds.append(.toolUse)
                if let id = b["id"] as? String { batch.openedToolUseIds.append(id) }
            default:
                break
            }
        }
        return batch
    }

    return empty
}

/// The structured events a Codex rollout record produces (mirrors
/// `codexRecordToEvents`, dropping the text). The discriminator is `payload.type`;
/// tool calls and their outputs are paired by `call_id`.
private func codexRecordBatch(_ rec: [String: Any]) -> StructuredEventBatch {
    let empty = StructuredEventBatch(kinds: [])
    guard let payload = rec["payload"] as? [String: Any],
          let type = payload["type"] as? String else { return empty }

    switch type {
    case "user_message":
        let m = payload["message"] as? String ?? ""
        return StructuredEventBatch(kinds: isBlank(m) ? [] : [.user])
    case "agent_message":
        let m = payload["message"] as? String ?? ""
        return StructuredEventBatch(kinds: isBlank(m) ? [] : [.assistant])
    case "reasoning":
        // Most reasoning is encrypted (`summary: []`); only a text summary counts.
        return StructuredEventBatch(kinds: isBlank(flattenText(payload["summary"])) ? [] : [.thinking])
    case "function_call", "custom_tool_call":
        return StructuredEventBatch(
            kinds: [.toolUse],
            openedToolUseIds: (payload["call_id"] as? String).map { [$0] } ?? [])
    case "function_call_output", "custom_tool_call_output":
        return StructuredEventBatch(
            kinds: [.toolResult],
            resolvedToolUseIds: (payload["call_id"] as? String).map { [$0] } ?? [])
    default:
        // token_count / task_started / session_meta / raw message items, etc.
        return empty
    }
}

/// Normalize one parsed transcript record into the structured events it carries.
public func transcriptRecordBatch(_ provider: ProviderId, _ rec: [String: Any]) -> StructuredEventBatch {
    provider == .claude ? claudeRecordBatch(rec) : codexRecordBatch(rec)
}

/// A byte-offset tailer over a session's transcript that emits batches of structured
/// kinds. Mirrors `TranscriptTail` in `structuredTranscript.ts`.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the immutable
/// collaborators are `let`.
public final class TranscriptActivityTail: @unchecked Sendable {
    public typealias BatchListener = @Sendable (_ batch: StructuredEventBatch, _ reset: Bool) -> Void

    private let provider: ProviderId
    /// A getter, not a value: Codex discovers its id shortly after spawn, so the tail
    /// re-reads it each poll until one appears.
    private let getCliSessionId: @Sendable () -> String?
    private let listener: BatchListener
    private let roots: TitleRoots
    private let pollMs: Int

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "juancode.activitytail")
    private var timer: DispatchSourceTimer?
    private var file: String?
    private var offset: UInt64 = 0
    /// Carries an incomplete trailing line between polls, at the byte level so a
    /// multi-byte character split across a read boundary is never mis-decoded.
    private var partial: [UInt8] = []
    private var sentBacklog = false
    private var polling = false

    public init(
        provider: ProviderId,
        cliSessionId: @escaping @Sendable () -> String?,
        roots: TitleRoots = TitleRoots(),
        pollMs: Int = 1000,
        listener: @escaping BatchListener
    ) {
        self.provider = provider
        self.getCliSessionId = cliSessionId
        self.roots = roots
        self.pollMs = pollMs
        self.listener = listener
    }

    /// Poll once immediately, then on an interval until `stop`.
    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(pollMs))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.poll() }
            }
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

    /// Read any new transcript bytes and emit their kinds. The first emission is the
    /// full backlog with `reset: true` (even when empty); later emissions carry only
    /// the appended kinds. Serialized against itself so a slow read can't overlap the
    /// next tick.
    public func poll() async {
        let claimed = lock.withLock { () -> Bool in
            if polling { return false }
            polling = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { polling = false } }

        if file == nil {
            guard let id = getCliSessionId() else { return } // id not captured yet (Codex)
            guard let resolved = await resolveTranscriptFile(provider, id, roots) else { return }
            file = resolved
        }
        guard let file else { return }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let sizeNum = attrs[.size] as? NSNumber else { return } // file vanished — leave as-is
        let size = sizeNum.uint64Value

        if size < offset {
            // Shouldn't happen for an append-only transcript, but recover if it does.
            offset = 0
            partial = []
        }

        var batch = StructuredEventBatch(kinds: [])
        if size > offset {
            guard let newBytes = readSlice(file, from: offset, upTo: size) else { return }
            offset = size
            partial.append(contentsOf: newBytes)
            let (complete, rest) = splitCompleteLines(partial)
            partial = rest
            for lineBytes in complete {
                guard !lineBytes.isEmpty,
                      let line = String(bytes: lineBytes, encoding: .utf8),
                      !isBlank(line),
                      let data = line.data(using: .utf8),
                      let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let one = transcriptRecordBatch(provider, rec)
                batch.kinds.append(contentsOf: one.kinds)
                batch.openedToolUseIds.append(contentsOf: one.openedToolUseIds)
                batch.resolvedToolUseIds.append(contentsOf: one.resolvedToolUseIds)
            }
        }

        if !sentBacklog {
            sentBacklog = true
            listener(batch, true)
        } else if !batch.kinds.isEmpty {
            listener(batch, false)
        }
    }

    /// Read the byte slice `[from, upTo)` from `file`, or nil on error.
    private func readSlice(_ file: String, from: UInt64, upTo: UInt64) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: from)
            let data = try handle.read(upToCount: Int(upTo - from)) ?? Data()
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    /// Split a byte buffer into complete lines (delimited by `\n`, delimiter dropped)
    /// plus the trailing partial line to carry forward.
    private func splitCompleteLines(_ bytes: [UInt8]) -> (complete: [[UInt8]], rest: [UInt8]) {
        var complete: [[UInt8]] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0x0A {
                complete.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        return (complete, current)
    }
}
