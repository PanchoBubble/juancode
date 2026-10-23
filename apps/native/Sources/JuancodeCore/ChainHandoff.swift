import Foundation

/// Durable chain handoffs over the wire (capability `chainHandoffs`, juancode-043.1).
///
/// The record is the daemon's (`juancoded-core/src/chain.rs`, `Handoff`): a transfer of
/// responsibility inside a chain from one owner to another, optionally about a Beads
/// issue. Beads stays the authority on the issue's own status; `beadsIssue` is only a
/// link to it. These are the shapes the native client decodes the `handoffs` and
/// `handoff` frames into. Read-only on this side for now (juancode-043.8): the writes
/// exist on the wire but nothing in the app sends them yet.

/// Who holds one end of a handoff: an explicit human, or a session by id. A session
/// that was removed after the handoff was written keeps its id here — history, never
/// reassigned — and a reader shows it as gone.
public enum ChainHandoffOwner: Codable, Sendable, Hashable {
    case human
    case session(String)

    private enum CodingKeys: String, CodingKey { case kind, sessionId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "human": self = .human
        case "session": self = .session(try c.decode(String.self, forKey: .sessionId))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown owner kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .human: try c.encode("human", forKey: .kind)
        case let .session(id):
            try c.encode("session", forKey: .kind)
            try c.encode(id, forKey: .sessionId)
        }
    }

    public var sessionId: String? {
        if case let .session(id) = self { return id }
        return nil
    }
}

/// Where a handoff is in its life. Delivery is tracked separately: a sent handoff is
/// not an acknowledged one.
public enum ChainHandoffState: String, Codable, Sendable {
    case pending
    case acknowledged
    case closed

    public var title: String {
        switch self {
        case .pending: return "Pending"
        case .acknowledged: return "Acknowledged"
        case .closed: return "Closed"
        }
    }
}

public enum ChainHandoffDelivery: String, Codable, Sendable {
    case notSent = "not_sent"
    case sent

    public var title: String {
        switch self {
        case .notSent: return "Not sent"
        case .sent: return "Sent"
        }
    }
}

/// One handoff record, as the daemon sends it.
public struct ChainHandoff: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var chainSlug: String
    public var source: ChainHandoffOwner
    public var target: ChainHandoffOwner
    public var beadsIssue: String?
    public var summary: String
    /// Epoch ms, stamped by the daemon.
    public var createdAt: Int
    public var updatedAt: Int
    public var state: ChainHandoffState
    public var closureReason: String?
    public var predecessorId: String?
    public var successorId: String?
    public var evidenceRef: String?
    public var delivery: ChainHandoffDelivery

    public init(id: String, chainSlug: String, source: ChainHandoffOwner,
                target: ChainHandoffOwner, beadsIssue: String? = nil, summary: String,
                createdAt: Int = 0, updatedAt: Int = 0, state: ChainHandoffState = .pending,
                closureReason: String? = nil, predecessorId: String? = nil,
                successorId: String? = nil, evidenceRef: String? = nil,
                delivery: ChainHandoffDelivery = .notSent) {
        self.id = id
        self.chainSlug = chainSlug
        self.source = source
        self.target = target
        self.beadsIssue = beadsIssue
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.closureReason = closureReason
        self.predecessorId = predecessorId
        self.successorId = successorId
        self.evidenceRef = evidenceRef
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey {
        case id, chainSlug, source, target, beadsIssue, summary, createdAt, updatedAt, state
        case closureReason, predecessorId, successorId, evidenceRef, delivery
    }

    /// The daemon defaults the stamped fields (`#[serde(default)]`), so a reader does too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chainSlug = try c.decode(String.self, forKey: .chainSlug)
        source = try c.decode(ChainHandoffOwner.self, forKey: .source)
        target = try c.decode(ChainHandoffOwner.self, forKey: .target)
        beadsIssue = try c.decodeIfPresent(String.self, forKey: .beadsIssue)
        summary = try c.decode(String.self, forKey: .summary)
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
        state = try c.decodeIfPresent(ChainHandoffState.self, forKey: .state) ?? .pending
        closureReason = try c.decodeIfPresent(String.self, forKey: .closureReason)
        predecessorId = try c.decodeIfPresent(String.self, forKey: .predecessorId)
        successorId = try c.decodeIfPresent(String.self, forKey: .successorId)
        evidenceRef = try c.decodeIfPresent(String.self, forKey: .evidenceRef)
        delivery = try c.decodeIfPresent(ChainHandoffDelivery.self, forKey: .delivery) ?? .notSent
    }

    /// Still somebody's to act on.
    public var isOpen: Bool { state != .closed }
}

/// A client's copy of the daemon's handoff history, kept by applying the frames in
/// order. Like `ChainBook`, every frame is whole — the full history or one record — so
/// re-applying one changes nothing.
public struct ChainHandoffBook: Sendable, Equatable {
    public private(set) var handoffs: [ChainHandoff]

    public init(_ handoffs: [ChainHandoff] = []) {
        self.handoffs = handoffs
    }

    public var isEmpty: Bool { handoffs.isEmpty }

    /// `handoffs`: replace everything.
    public mutating func replace(with handoffs: [ChainHandoff]) {
        self.handoffs = handoffs
    }

    /// `handoff`: replace one record, or add it at the end.
    public mutating func upsert(_ handoff: ChainHandoff) {
        if let i = handoffs.firstIndex(where: { $0.id == handoff.id }) {
            handoffs[i] = handoff
        } else {
            handoffs.append(handoff)
        }
    }

    /// One chain's handoffs, oldest first.
    public func handoffs(in slug: String) -> [ChainHandoff] {
        handoffs.filter { $0.chainSlug == slug }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}
