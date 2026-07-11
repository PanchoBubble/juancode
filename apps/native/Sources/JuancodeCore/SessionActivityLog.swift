import Foundation

/// Sink for session lifecycle + activity events (spawn, seed delivery, activity
/// transitions, watchdog settles, exits, revives, health flags). The default is a
/// no-op so tests and bare `SessionEnvironment()`s stay quiet; the app installs a
/// `SessionActivityLog` writing JSONL to disk, giving a durable trail to debug
/// frozen sessions after the fact (a stuck seed delivery used to leave no trace).
///
/// Privacy: callers log event names, states, byte counts, attempt numbers and exit
/// codes — never prompt or transcript contents. The file logger additionally clips
/// every field value hard, so an error message can't smuggle a transcript in.
public protocol SessionActivityLogging: Sendable {
    func log(_ event: String, sessionId: String, project: String, fields: [String: String])
}

public extension SessionActivityLogging {
    func log(_ event: String, sessionId: String, project: String) {
        log(event, sessionId: sessionId, project: project, fields: [:])
    }
}

/// The quiet default.
public struct NoopSessionActivityLog: SessionActivityLogging {
    public init() {}
    public func log(_ event: String, sessionId: String, project: String, fields: [String: String]) {}
}

/// Rolling on-disk JSONL activity log: one JSON object per line
/// (`{"ts":…,"event":…,"session":…,"project":…, …fields}`), size-rotated at
/// `maxBytes` into a single `.1` sibling — the same capping philosophy as the
/// scrollback ring and the per-project DB retention, applied to diagnostics.
/// Appends hand off to a dedicated serial queue so callers (the session
/// workQueue, detector queue, UI) never block on disk I/O.
///
/// `@unchecked Sendable`: the mutable file handle + size counter are touched only
/// on `queue`; everything else is `let`.
public final class SessionActivityLog: SessionActivityLogging, @unchecked Sendable {
    public static let fileName = "session-activity.log"
    /// Hard cap on any single field value, so free-text (error reasons) stays a
    /// diagnostic breadcrumb and never a content leak.
    static let maxFieldChars = 80

    /// The active log file. Grep by session id to follow one session's trail.
    public let logPath: String
    private let rotatedPath: String
    private let directory: String
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "juancode.session-activity-log", qos: .utility)
    /// Thread-safe per Apple docs; millisecond precision for ordering bursts.
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Touched only on `queue`.
    private var handle: FileHandle?
    private var currentSize = 0

    public init(
        directory: String = Config.logsDir,
        maxBytes: Int = 5 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.now = now
        self.logPath = (directory as NSString).appendingPathComponent(Self.fileName)
        self.rotatedPath = self.logPath + ".1"
    }

    deinit {
        try? handle?.close()
    }

    public func log(_ event: String, sessionId: String, project: String, fields: [String: String]) {
        let ts = iso.string(from: now())
        queue.async { [self] in
            var obj: [String: String] = [:]
            for (k, v) in fields { obj[k] = Self.clip(v) }
            obj["ts"] = ts
            obj["event"] = event
            obj["session"] = sessionId
            obj["project"] = project
            guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            else { return }
            data.append(0x0A)
            append(data)
        }
    }

    /// Drain pending appends and sync the file — for tests and crash-adjacent reads.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: - internals (on `queue`)

    private func append(_ data: Data) {
        if handle == nil { open() }
        if currentSize > 0, currentSize + data.count > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // Disk trouble must never take a session down; drop the line.
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: logPath) else { return }
        currentSize = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(atPath: rotatedPath)
        try? fm.moveItem(atPath: logPath, toPath: rotatedPath)
        open()
    }

    private static func clip(_ s: String) -> String {
        s.count <= maxFieldChars ? s : String(s.prefix(maxFieldChars)) + "…"
    }
}
