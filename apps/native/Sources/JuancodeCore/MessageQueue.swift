import Foundation

/// One message the user queued to a session while it was busy. Queued items are
/// persisted per-session and delivered in order (`createdAt` / insertion order) on
/// the next idle. The wire shape mirrors `QueuedMessage` in
/// `apps/server/src/protocol.ts` (`{ id, text, createdAt }`).
public struct QueuedMessage: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    /// Epoch ms the message was queued.
    public let createdAt: Int

    public init(id: String = UUID().uuidString.lowercased(), text: String, createdAt: Int = nowMs()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Persistence seam for the per-session outbound message queue (mirrors the
/// surface of `messageQueueDb` in `apps/server/src/db.ts`). The in-memory impl
/// below is the testable default; the GRDB/SQLite impl (in `JuancodePersistence`)
/// conforms to this so the queue survives a reconnect / restart / reactivation.
/// Insertion order *is* delivery order.
public protocol MessageQueuePersistence: AnyObject, Sendable {
    /// Append a message to a session's queue, returning the stored item.
    @discardableResult func add(_ sessionId: String, text: String) -> QueuedMessage
    /// A session's pending messages, in delivery (insertion) order.
    func list(_ sessionId: String) -> [QueuedMessage]
    /// The next message to deliver, or nil when the queue is empty.
    func first(_ sessionId: String) -> QueuedMessage?
    /// Remove one queued message; returns true when it belonged to the session.
    @discardableResult func remove(_ sessionId: String, _ id: String) -> Bool
}

/// Default persistence: keeps every queue in memory for the process lifetime.
/// Thread-safe via a lock so the pty work queue and WS handler threads can both
/// hit it. Insertion order is preserved by appending to a per-session array.
public final class InMemoryMessageQueue: MessageQueuePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [QueuedMessage]] = [:]

    public init() {}

    @discardableResult
    public func add(_ sessionId: String, text: String) -> QueuedMessage {
        let item = QueuedMessage(text: text)
        lock.withLock { queues[sessionId, default: []].append(item) }
        return item
    }

    public func list(_ sessionId: String) -> [QueuedMessage] {
        lock.withLock { queues[sessionId] ?? [] }
    }

    public func first(_ sessionId: String) -> QueuedMessage? {
        lock.withLock { queues[sessionId]?.first }
    }

    @discardableResult
    public func remove(_ sessionId: String, _ id: String) -> Bool {
        lock.withLock {
            guard var list = queues[sessionId] else { return false }
            let before = list.count
            list.removeAll { $0.id == id }
            if list.isEmpty { queues[sessionId] = nil } else { queues[sessionId] = list }
            return list.count < before
        }
    }
}

/// The per-session outbound message queue, backed by a `MessageQueuePersistence`
/// with an in-memory fan-out so every watcher (WS connection) and the delivering
/// `Session` see the same ordered list. Mutations persist first, then notify — so
/// the queue survives a reconnect / restart and a session reactivation, and is
/// flushed exactly once regardless of how many tabs are watching.
///
/// A faithful port of `MessageQueueStore` in `apps/server/src/messageQueue.ts`.
/// `@unchecked Sendable`: the listener map is only mutated under `lock`; the
/// persistence collaborator is `let` and itself Sendable.
public final class MessageQueue: @unchecked Sendable {
    public typealias Listener = @Sendable (_ items: [QueuedMessage]) -> Void

    private let persistence: MessageQueuePersistence
    private let lock = NSLock()
    private var listeners: [String: [Int: Listener]] = [:]
    private var nextToken = 0

    public init(persistence: MessageQueuePersistence = InMemoryMessageQueue()) {
        self.persistence = persistence
    }

    /// A session's pending messages, in delivery order.
    public func list(_ sessionId: String) -> [QueuedMessage] {
        persistence.list(sessionId)
    }

    /// The next message to deliver, or nil when the queue is empty.
    public func peek(_ sessionId: String) -> QueuedMessage? {
        persistence.first(sessionId)
    }

    /// Append a message and notify watchers; returns the stored item.
    @discardableResult
    public func add(_ sessionId: String, text: String) -> QueuedMessage {
        let item = persistence.add(sessionId, text: text)
        emit(sessionId)
        return item
    }

    /// Remove one message (cancel or post-delivery) and notify; true if it existed.
    @discardableResult
    public func remove(_ sessionId: String, _ id: String) -> Bool {
        let removed = persistence.remove(sessionId, id)
        if removed { emit(sessionId) }
        return removed
    }

    /// Watch a session's queue; the listener is *not* called immediately (the WS
    /// layer sends the current snapshot itself on subscribe). Returns a cancel handle.
    @discardableResult
    public func onChange(_ sessionId: String, _ listener: @escaping Listener) -> @Sendable () -> Void {
        let token = lock.withLock { () -> Int in
            let t = nextToken; nextToken += 1
            listeners[sessionId, default: [:]][t] = listener
            return t
        }
        return { [weak self] in
            self?.lock.withLock {
                self?.listeners[sessionId]?.removeValue(forKey: token)
                if self?.listeners[sessionId]?.isEmpty == true { self?.listeners[sessionId] = nil }
            }
        }
    }

    private func emit(_ sessionId: String) {
        let subs = lock.withLock { listeners[sessionId]?.values.map { $0 } ?? [] }
        guard !subs.isEmpty else { return }
        let items = list(sessionId)
        for l in subs { l(items) }
    }
}
