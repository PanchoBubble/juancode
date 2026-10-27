import Foundation
import JuancodeCore

/// Chains over the wire (capability `chains`, juancode-dbo.1).
///
/// The book is the daemon's; this keeps the last copy it sent and hands it, whole, to
/// every watcher after each frame. Every frame the daemon sends for chains is whole —
/// the book, one chain, or one removal — so applying them in arrival order converges
/// on the daemon's book without a sequence number.
extension RustCoreClient {
    /// How long a chain write waits for its `chainResult`. A write is one row in a local
    /// SQLite file, so anything near this is a daemon that is not answering.
    static let chainWriteTimeout: TimeInterval = 10

    /// One subscription per connection, sent once and again after a reconnect.
    func ensureChainSubscription() {
        guard supports(.chains) else { return }
        let send: Bool = lock.withLock {
            guard !chainSubscribed, !chainListeners.isEmpty else { return false }
            chainSubscribed = true
            return true
        }
        if send { connection.send(["type": "subscribeChains"]) }
    }

    public func subscribeChains(
        _ onBook: @escaping @Sendable (ChainBook) -> Void) -> @Sendable () -> Void {
        guard supports(.chains) else {
            onBook(ChainBook())
            return {}
        }
        let (token, known) = lock.withLock { () -> (Int, ChainBook?) in
            let t = nextListenerToken
            nextListenerToken += 1
            chainListeners[t] = onBook
            return (t, chainBook)
        }
        ensureChainSubscription()
        // A connection already holding the book hands it over now; otherwise the
        // hand-over is the daemon's answer to the subscribe just sent.
        if let known { onBook(known) }
        return { [weak self] in
            guard let self else { return }
            // No unsubscribe frame: the daemon's watch is one small book per change and
            // ends with the socket, so the frames just stop being forwarded here.
            lock.withLock { _ = chainListeners.removeValue(forKey: token) }
        }
    }

    public func createChain(_ slug: String) async throws {
        try await chainWrite(["type": "createChain", "slug": slug])
    }

    public func createChain(id: String, name: String) async throws {
        try await chainWrite(["type": "createChain", "slug": id, "name": name])
    }

    public func closeChain(_ slug: String) async throws {
        try await chainWrite(["type": "closeChain", "slug": slug])
    }

    public func reopenChain(_ slug: String) async throws {
        try await chainWrite(["type": "reopenChain", "slug": slug])
    }

    public func deleteChain(_ slug: String) async throws {
        try await chainWrite(["type": "deleteChain", "slug": slug])
    }

    public func setChainMember(_ kind: ChainMemberKind, ref: String, slug: String?,
                               title: String?, url: String?) async throws {
        var frame: [String: Any] = ["type": "setChainMember", "kind": kind.rawValue, "ref": ref]
        // Absent, not null, when untagging: both mean "no chain" to the daemon, and an
        // absent key is what every other optional field on this wire looks like.
        if let slug { frame["slug"] = slug }
        if let title { frame["title"] = title }
        if let url { frame["url"] = url }
        try await chainWrite(frame)
    }

    /// One write, correlated on its `requestId`. Silence is a failure, never a success:
    /// a tag nobody confirmed has not landed.
    private func chainWrite(_ frame: [String: Any]) async throws {
        guard supports(.chains) else { throw ChainError("chain-unavailable") }
        let waiter = ChangesWaiter()
        let requestId = lock.withLock { () -> String in
            let id = "chain-\(nextChainId)"
            nextChainId += 1
            chainWaiters[id] = waiter
            return id
        }
        var body = frame
        body["requestId"] = requestId
        connection.send(body)
        defer { lock.withLock { chainWaiters[requestId] = nil } }
        guard let reply = await waiter.wait(timeout: Self.chainWriteTimeout) else {
            throw ChainError("chain-timeout")
        }
        if let code = reply.error, !code.isEmpty { throw ChainError(code) }
    }

    /// The four chain frames. Called from the frame switch.
    func handleChainFrame(_ type: String, _ body: [String: Any]) {
        switch type {
        case "chainResult":
            guard let requestId = body["requestId"] as? String else { return }
            let waiter = lock.withLock { chainWaiters.removeValue(forKey: requestId) }
            waiter?.deliver(body)
            return
        case "chains":
            let chains = (body["chains"] as? [Any] ?? [])
                .compactMap { Self.decodeJSON(Chain.self, $0) }
            publishChains { $0.replace(with: chains) }
        case "chain":
            guard let chain = Self.decodeJSON(Chain.self, body["chain"]) else { return }
            publishChains { $0.upsert(chain) }
        case "chainRemoved":
            guard let slug = body["slug"] as? String else { return }
            publishChains { $0.remove(slug: slug) }
        default:
            return
        }
    }

    private func publishChains(_ apply: (inout ChainBook) -> Void) {
        let (book, listeners) = lock.withLock { () -> (ChainBook, [@Sendable (ChainBook) -> Void]) in
            var book = chainBook ?? ChainBook()
            apply(&book)
            chainBook = book
            return (book, Array(chainListeners.values))
        }
        for l in listeners { l(book) }
    }
}

/// A chain write the core refused or never confirmed. `code` is the core's
/// (`chain-exists`, `chain-not-found`, …) or this client's (`chain-timeout`,
/// `chain-connection-lost`, `chain-unavailable`).
public struct ChainError: LocalizedError, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }

    public var errorDescription: String? {
        switch code {
        case "chain-exists": return "A chain with that name already exists."
        case "chain-not-found": return "That chain no longer exists."
        case "chain-member-not-found": return "That session no longer exists."
        case "chain-slug-empty": return "A chain needs a name."
        case "chain-slug-invalid":
            return "A chain name is lowercase letters and digits, separated by single dashes."
        case "chain-slug-too-long": return "That chain name is too long."
        case "chain-unavailable": return "This core does not support chains."
        case "chain-timeout": return "The core did not confirm the change, so it has not happened."
        case "chain-connection-lost":
            return "The connection to the core dropped before it confirmed the change."
        default: return "The chain change failed (\(code))."
        }
    }
}

/// Chain handoffs over the wire (capability `chainHandoffs`, juancode-043.1). Read-only
/// here (juancode-043.8): the history is subscribed to and mirrored whole; the write
/// frames exist on the daemon, but no surface of this client sends them yet.
extension RustCoreClient {
    /// One subscription per connection, sent once and again after a reconnect.
    func ensureHandoffSubscription() {
        guard supports(.chainHandoffs) else { return }
        let send: Bool = lock.withLock {
            guard !handoffSubscribed, !handoffListeners.isEmpty else { return false }
            handoffSubscribed = true
            return true
        }
        if send { connection.send(["type": "subscribeHandoffs"]) }
    }

    public func subscribeHandoffs(
        _ onBook: @escaping @Sendable (ChainHandoffBook) -> Void) -> @Sendable () -> Void {
        // An older daemon has no history to send: hand over an empty book once, and let
        // the caller read `supports(.chainHandoffs)` to tell "none" from "can't know".
        guard supports(.chainHandoffs) else {
            onBook(ChainHandoffBook())
            return {}
        }
        let (token, known) = lock.withLock { () -> (Int, ChainHandoffBook?) in
            let t = nextListenerToken
            nextListenerToken += 1
            handoffListeners[t] = onBook
            return (t, handoffBook)
        }
        ensureHandoffSubscription()
        if let known { onBook(known) }
        return { [weak self] in
            guard let self else { return }
            lock.withLock { _ = handoffListeners.removeValue(forKey: token) }
        }
    }

    /// The handoff frames. Called from the frame switch.
    func handleHandoffFrame(_ type: String, _ body: [String: Any]) {
        switch type {
        case "handoffs":
            let handoffs = (body["handoffs"] as? [Any] ?? [])
                .compactMap { Self.decodeJSON(ChainHandoff.self, $0) }
            publishHandoffs { $0.replace(with: handoffs) }
        case "handoff":
            guard let handoff = Self.decodeJSON(ChainHandoff.self, body["handoff"]) else { return }
            publishHandoffs { $0.upsert(handoff) }
        default:
            // `handoffResult` answers a write, and this client sends none.
            return
        }
    }

    private func publishHandoffs(_ apply: (inout ChainHandoffBook) -> Void) {
        let (book, listeners) = lock.withLock {
            () -> (ChainHandoffBook, [@Sendable (ChainHandoffBook) -> Void]) in
            var book = handoffBook ?? ChainHandoffBook()
            apply(&book)
            handoffBook = book
            return (book, Array(handoffListeners.values))
        }
        for l in listeners { l(book) }
    }
}
