import Foundation

/// The Oracle control directory's on-disk protocol: where the files live, how a
/// JSONL mailbox is appended to and tailed, the durable dispatch-outcome log, and
/// the process-wide dedup ledger.
///
/// Split out of `Oracle.swift` (juancode-a2s7). The rest of Oracle — the dispatch
/// and state-snapshot types, the control-dir bootstrap and the agent instructions —
/// is desktop-local and lives in `JuancodeDesktop/Oracle.swift`. This half stays
/// here because the in-process WS server claims dispatch ids and records their
/// outcomes (`JuancodeServer/WebSocketConnection.swift`), and `JuancodeServer`
/// must not depend on `JuancodeDesktop`.
///
/// Its Rust counterpart already exists: `claim_dispatch` in juancoded-persistence
/// plus the `dispatch_id` claim in juancoded-state's `create`. So this file shares
/// `ReviveSession.swift`'s fate — it goes when the in-process server does
/// (juancode-nqpm / juancode-3s4p), and nothing new should be added to it.

public enum OraclePaths {
    /// `~/.juancode/oracle`, overridable via `JUANCODE_ORACLE_DIR` (used by tests).
    /// Read via `getenv` (not `ProcessInfo.environment`, which bridges the whole
    /// environ into a fresh dictionary per call): this getter sits inside per-render
    /// session-list filters, where it showed up hot in CPU samples (juancode-idq).
    /// `getenv` still reflects a test's `setenv` between cases.
    public static var controlDir: String {
        if let raw = getenv("JUANCODE_ORACLE_DIR"), raw.pointee != 0 { return String(cString: raw) }
        return defaultControlDir
    }
    private static let defaultControlDir =
        (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/oracle")
    public static var beadsDir: String { join(controlDir, ".beads") }
    public static var gitDir: String { join(controlDir, ".git") }
    public static var agentsFile: String { join(controlDir, "AGENTS.md") }
    public static var stateFile: String { join(controlDir, "state.json") }
    public static var dispatchFile: String { join(controlDir, "dispatch.jsonl") }
    public static var askFile: String { join(controlDir, "ask.jsonl") }
    /// Byte offset into `dispatch.jsonl` consumed so far, persisted so lines queued
    /// while the app was down are replayed exactly once on the next launch.
    public static var dispatchOffsetFile: String { join(controlDir, "dispatch.offset") }
    /// Byte offset into `ask.jsonl` consumed so far (mirrors `dispatchOffsetFile`).
    public static var askOffsetFile: String { join(controlDir, "ask.offset") }
    /// Durable per-dispatch outcomes (`OracleDispatchResult` lines) the sidecar tails
    /// to relay success/failure to the remote caller (console/Telegram).
    public static var dispatchResultsFile: String { join(controlDir, "dispatch-results.jsonl") }
    /// Processed dispatch ids (see `OracleDispatchLedger`), so a dispatch delivered
    /// over the WS that ALSO landed in the mailbox during a race isn't started twice.
    public static var processedDispatchFile: String { join(controlDir, "dispatch-processed.json") }

    private static func join(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }
}

/// Append `value` as one JSON line to an append-only mailbox file. Shared by the
/// dispatch and ask mailboxes so both use one write path.
public func appendJSONLine<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var line = try encoder.encode(value)
    line.append(0x0A) // newline
    let url = URL(fileURLWithPath: path)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    } else {
        try line.write(to: url)
    }
}

/// Decode any complete JSON lines of `T` starting at byte `offset`, returning the
/// parsed values and the new offset to resume from. A trailing partial line (no
/// newline yet) is left unconsumed so a half-written append isn't misparsed.
/// Malformed lines are skipped (never throw) so one bad line can't wedge the tail.
/// A shrunken/rotated file resets the offset to the new end. Shared by both mailboxes.
public func readJSONL<T: Decodable>(_ type: T.Type, at path: String, since offset: Int) -> (items: [T], offset: Int) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { return ([], offset) }
    guard offset <= data.count else { return ([], data.count) } // file shrank/rotated
    let fresh = data.subdata(in: offset..<data.count)
    guard let lastNewline = fresh.lastIndex(of: 0x0A) else { return ([], offset) }
    let consumable = fresh.subdata(in: 0..<(lastNewline + 1))
    let decoder = JSONDecoder()
    var out: [T] = []
    for lineData in consumable.split(separator: 0x0A) where !lineData.isEmpty {
        if let d = try? decoder.decode(T.self, from: Data(lineData)) { out.append(d) }
    }
    return (out, offset + consumable.count)
}


// MARK: - Durable dispatch outcomes + mailbox offsets + dedup ledger

/// The durable outcome of one dispatch (WS- or mailbox-delivered), appended to
/// `dispatch-results.jsonl` so the sidecar can tail it and relay success/failure to
/// the remote caller (console/Telegram) — a rejection must never live only as a
/// message typed into the live Oracle pty.
public struct OracleDispatchResult: Codable, Sendable, Equatable {
    /// The dispatch's caller-minted id; nil for agent-written mailbox lines.
    public var dispatchId: String?
    /// The dispatch's target project path, for a human-readable relay.
    public var project: String
    public var ok: Bool
    /// The spawned session's id (ok == true).
    public var sessionId: String?
    /// What went wrong (ok == false).
    public var error: String?
    /// ms since epoch.
    public var at: Int

    public init(dispatchId: String?, project: String, ok: Bool,
                sessionId: String? = nil, error: String? = nil, at: Int) {
        self.dispatchId = dispatchId
        self.project = project
        self.ok = ok
        self.sessionId = sessionId
        self.error = error
        self.at = at
    }
}

/// Result appends can race between the WS handler (server thread) and the mailbox
/// tail (main actor) — one lock keeps the JSONL lines whole.
private let dispatchResultLock = NSLock()

/// Append one dispatch outcome to `dispatch-results.jsonl` (thread-safe).
public func appendOracleDispatchResult(_ result: OracleDispatchResult) throws {
    dispatchResultLock.lock()
    defer { dispatchResultLock.unlock() }
    try appendJSONLine(result, to: OraclePaths.dispatchResultsFile)
}

/// Decode any complete result lines starting at byte `offset`. See `readJSONL`.
public func readOracleDispatchResults(since offset: Int) -> (results: [OracleDispatchResult], offset: Int) {
    let r = readJSONL(OracleDispatchResult.self, at: OraclePaths.dispatchResultsFile, since: offset)
    return (r.items, r.offset)
}

/// Read a persisted mailbox byte offset; nil when the file is absent/corrupt (first
/// run under the offset scheme — callers then prime to EOF, preserving the old
/// "only act on lines appended this run" behavior exactly once).
public func readOracleMailboxOffset(at path: String) -> Int? {
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return nil }
    guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return nil }
    return value
}

/// Persist a mailbox byte offset (best-effort; a failed write just means a replay
/// window on next launch, which the dispatch-id ledger de-duplicates).
public func writeOracleMailboxOffset(_ offset: Int, at path: String) {
    try? Data("\(offset)\n".utf8).write(to: URL(fileURLWithPath: path))
}

/// Process-wide registry of dispatch ids already turned into sessions, persisted to
/// `dispatch-processed.json`. Both delivery routes claim before spawning — the WS
/// `create` handler and the mailbox tail — so a dispatch that raced onto both paths
/// (WS ack lost, sidecar appended the same id as a fallback) starts exactly once,
/// across launches. Bounded: only the most recent `capacity` ids are kept.
public final class OracleDispatchLedger: @unchecked Sendable {
    public static let shared = OracleDispatchLedger()

    private let lock = NSLock()
    private let capacity: Int
    private let pathProvider: () -> String
    private var loaded = false
    private var ids = Set<String>()
    private var order: [String] = []

    /// `path` defaults to `OraclePaths.processedDispatchFile` (resolved lazily so
    /// the shared instance honors `JUANCODE_ORACLE_DIR`); injectable for tests.
    public init(capacity: Int = 512, path: (() -> String)? = nil) {
        self.capacity = capacity
        self.pathProvider = path ?? { OraclePaths.processedDispatchFile }
    }

    /// Atomically claim `id`: true when it was unclaimed (caller proceeds to spawn),
    /// false when some route already processed it (caller must skip).
    public func claim(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard !ids.contains(id) else { return false }
        ids.insert(id)
        order.append(id)
        if order.count > capacity {
            for evicted in order.prefix(order.count - capacity) { ids.remove(evicted) }
            order.removeFirst(order.count - capacity)
        }
        persist()
        return true
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pathProvider())),
              let stored = try? JSONDecoder().decode([String].self, from: data) else { return }
        order = stored.suffix(capacity)
        ids = Set(order)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: URL(fileURLWithPath: pathProvider()))
    }
}
