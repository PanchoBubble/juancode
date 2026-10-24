import Foundation

/// Untrusted OSC 7501 metadata. Never an approval, input action, or readiness signal.
public struct ProgramStatusRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: String
    public var kind: String?
    public var app: String?
    public var title: String?
    public var msg: String?
    public var progress: Int?

    public var summary: String {
        [app, state, progress.map { "\($0)%" }, title, msg]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Older peers omit the event; future states remain visible as metadata.
    public static func decode(_ raw: Any?) -> [Self]? {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([Self].self, from: data)
    }
}

/// Shared subscription storage for session and plain-shell status presentation.
public final class ProgramStatusFeed: @unchecked Sendable {
    public typealias Listener = @Sendable ([ProgramStatusRecord]) -> Void
    private let lock = NSRecursiveLock()
    private var records: [ProgramStatusRecord] = []
    private var listeners: [UUID: Listener] = [:]
    public init() {}

    public func replace(_ records: [ProgramStatusRecord]) {
        lock.lock(); defer { lock.unlock() }
        guard self.records != records else { return }
        self.records = records
        for listener in Array(listeners.values) { listener(records) }
    }

    /// Replay and publication share a lock, so a delayed replay cannot replace newer data.
    public func observe(_ listener: @escaping Listener) -> @Sendable () -> Void {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        listeners[token] = listener
        listener(records)
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.listeners[token] = nil
        }
    }
}
