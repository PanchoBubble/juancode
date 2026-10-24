import Foundation
import JuancodeCore

extension RustCoreClient {
    func ensureAttentionSubscription() {
        guard supports(.attention) else { publishAttention(nil); return }
        let send = lock.withLock {
            guard !attentionSubscribed, !attentionListeners.isEmpty else { return false }
            attentionSubscribed = true
            return true
        }
        if send { connection.send(["type": "subscribeAttention"]) }
    }
    public func subscribeAttention(_ listener: @escaping @Sendable ([AttentionItem]?) -> Void) -> @Sendable () -> Void {
        let (token, known) = lock.withLock {
            let token = nextListenerToken
            nextListenerToken += 1
            attentionListeners[token] = listener
            return (token, attentionItems)
        }
        listener(known)
        ensureAttentionSubscription()
        return { [weak self] in
            guard let self else { return }
            _ = lock.withLock { attentionListeners.removeValue(forKey: token) }
        }
    }
    public func acknowledgeAttention(_ id: String) async throws {
        guard supports(.attention) else { throw CoreCapabilityError(.attention, backend: backendName) }
        let waiter = ChangesWaiter()
        let requestId = lock.withLock {
            let requestId = "attention-\(nextChangesId)"
            nextChangesId += 1
            changesWaiters[requestId] = waiter
            return requestId
        }
        defer { _ = lock.withLock { changesWaiters.removeValue(forKey: requestId) } }
        connection.send(["type": "acknowledgeAttention", "id": id, "requestId": requestId])
        guard let reply = await waiter.wait(timeout: 10) else { throw AttentionError("attention-timeout") }
        if let error = reply.error { throw AttentionError(error) }
    }
    func handleAttentionFrame(_ type: String, _ body: [String: Any]) {
        if type == "attentionResult" {
            guard let id = body["requestId"] as? String else { publishAttention(nil); return }
            let waiter = lock.withLock { changesWaiters.removeValue(forKey: id) }
            if body["ok"] as? Bool == true { waiter?.deliver(body) }
            else { waiter?.fail(body["error"] as? String ?? "attention-failed") }
        } else if let raw = body["items"] as? [Any] {
            let items = raw.compactMap { Self.decodeJSON(AttentionItem.self, $0) }
            guard items.count == raw.count else { return }
            publishAttention(items)
        }
    }
    func publishAttention(_ items: [AttentionItem]?) {
        let listeners = lock.withLock {
            attentionItems = items
            return Array(attentionListeners.values)
        }
        for listener in listeners { listener(items) }
    }
}

public struct AttentionError: LocalizedError {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "attention-unavailable": return "The attention inbox is unavailable."
        case "attention-not-found": return "This attention item is no longer available."
        case "attention-timeout": return "The daemon did not confirm marking this item read."
        default: return code
        }
    }
}
