import Foundation
import Testing
@testable import JuancodeCore

/// Unit tests for the per-session outbound message queue (oracle-cj3 / juancode-r82).
/// Mirrors `apps/server/src/messageQueue.test.ts`: insertion-ordered queue/list/
/// peek/remove, per-session isolation, and the change fan-out the WS layer relies on.
@Suite struct MessageQueueTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[QueuedMessage]] = []
        func record(_ items: [QueuedMessage]) { lock.withLock { snapshots.append(items) } }
        var all: [[QueuedMessage]] { lock.withLock { snapshots } }
        var last: [QueuedMessage]? { lock.withLock { snapshots.last } }
        var count: Int { lock.withLock { snapshots.count } }
    }

    @Test func queuesListsInOrderPeeksHeadAndRemoves() {
        let q = MessageQueue(persistence: InMemoryMessageQueue())
        let s = "session-1"
        let a = q.add(s, text: "first")
        let b = q.add(s, text: "second")
        let c = q.add(s, text: "third")

        #expect(q.list(s).map(\.text) == ["first", "second", "third"])
        #expect(q.peek(s)?.id == a.id)

        // Remove the middle one.
        #expect(q.remove(s, b.id) == true)
        #expect(q.list(s).map(\.text) == ["first", "third"])

        // Remove the head; peek follows to the next.
        #expect(q.remove(s, a.id) == true)
        #expect(q.peek(s)?.id == c.id)

        #expect(q.remove(s, c.id) == true)
        #expect(q.peek(s) == nil)
        #expect(q.list(s).isEmpty)
    }

    @Test func removingAnUnknownIdReturnsFalseAndDoesNotNotify() {
        let q = MessageQueue(persistence: InMemoryMessageQueue())
        let s = "session-x"
        q.add(s, text: "only")
        let watcher = Collector()
        _ = q.onChange(s) { watcher.record($0) }
        #expect(q.remove(s, "nope") == false)
        #expect(watcher.count == 0) // no change → no fan-out
    }

    @Test func isolatesQueuesPerSession() {
        let q = MessageQueue(persistence: InMemoryMessageQueue())
        q.add("session-A", text: "a-msg")
        q.add("session-B", text: "b-msg")
        #expect(q.list("session-A").map(\.text) == ["a-msg"])
        #expect(q.list("session-B").map(\.text) == ["b-msg"])

        let aItem = q.list("session-A")[0]
        // Removing A's item against B's queue is a no-op.
        #expect(q.remove("session-B", aItem.id) == false)
        #expect(q.list("session-A").count == 1)
    }

    @Test func onChangeFiresOnAddAndRemoveWithTheCurrentSnapshot() {
        let q = MessageQueue(persistence: InMemoryMessageQueue())
        let s = "session-watch"
        let watcher = Collector()
        let off = q.onChange(s) { watcher.record($0) }

        let a = q.add(s, text: "one")
        q.add(s, text: "two")
        #expect(watcher.count == 2)
        #expect(watcher.last?.map(\.text) == ["one", "two"])

        #expect(q.remove(s, a.id) == true)
        #expect(watcher.count == 3)
        #expect(watcher.last?.map(\.text) == ["two"])

        // After cancelling, no more notifications arrive.
        off()
        q.add(s, text: "three")
        #expect(watcher.count == 3)
    }

    @Test func onChangeIsScopedToItsSession() {
        let q = MessageQueue(persistence: InMemoryMessageQueue())
        let watcher = Collector()
        _ = q.onChange("session-A") { watcher.record($0) }
        q.add("session-B", text: "elsewhere")
        #expect(watcher.count == 0)
        q.add("session-A", text: "here")
        #expect(watcher.count == 1)
    }

    @Test func queuedMessageWireShapeMatchesProtocol() throws {
        // The wire shape is a contract with the web client / protocol.ts
        // (`{ id, text, createdAt }`). Pin the JSON keys.
        let item = QueuedMessage(id: "abc", text: "hello", createdAt: 1234)
        let data = try JSONEncoder().encode(item)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["id"] as? String == "abc")
        #expect(obj["text"] as? String == "hello")
        #expect(obj["createdAt"] as? Int == 1234)
        #expect(obj.keys.count == 3)
    }
}
