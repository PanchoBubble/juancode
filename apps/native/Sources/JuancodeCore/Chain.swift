import Foundation

/// Chains: named, cross-project groups of related work (juancode-dbo).
///
/// The book lives in the daemon (`juancoded-core/src/chain.rs` for the model,
/// `juancoded-server/src/chains.rs` for the engine) and reaches every client over the
/// `chains` capability. These are the shapes it decodes into, in `JuancodeCore`
/// because both `JuancodeServer/WireProtocol.swift` and `JuancodeClient` carry them.
///
/// A chain has a stable UUID and display name. `slug` is retained as a compatibility
/// routing key for existing links; newly named chains use the UUID. An item
/// is in at most one chain, so membership is answered by a lookup over the book rather
/// than by a field on the item — which is why a session's chain is not on `SessionMeta`.

/// Whether a chain is still being worked. A closed chain keeps its members.
public enum ChainState: String, Codable, Sendable {
    case active
    case inactive
}

/// What a member is. The `ref` that goes with it is the id that kind already has: a
/// session id (Oracles included), a tracked PR's key (`<cwd>#<number>`), a beads issue
/// id, or a Linear identifier.
public enum ChainMemberKind: String, Codable, Sendable, CaseIterable {
    case session
    case trackedPr = "tracked_pr"
    case beads
    case linear
}

/// One item in a chain. `title`/`url` are the snapshot taken when it was tagged, for
/// the kinds the daemon cannot look up itself (beads, Linear); a session's live title
/// is on its `SessionMeta`.
public struct ChainMember: Codable, Sendable, Equatable, Hashable {
    public var kind: ChainMemberKind
    public var ref: String
    public var title: String?
    public var url: String?
    /// Epoch ms the item joined this chain.
    public var addedAt: Int
    /// The loop role a dispatch gave it (`orchestrator`, `planner`, `implementer`,
    /// `tester`); nil in an unroled chain.
    public var role: String?

    public init(kind: ChainMemberKind, ref: String, title: String? = nil, url: String? = nil,
                addedAt: Int = 0, role: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.title = title
        self.url = url
        self.addedAt = addedAt
        self.role = role
    }
}

/// A chain and everything in it, members in the order they joined.
public struct Chain: Codable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var id: String
    public var state: ChainState
    public var createdAt: Int
    /// When it was last closed; nil while active.
    public var closedAt: Int?
    public var members: [ChainMember]
    /// The slug of the chain this one nests under (a sub-orchestrator's chain,
    /// juancode-8oa5.9); nil for a top-level chain.
    public var parent: String?

    public var isActive: Bool { state == .active }

    public init(slug: String, id: String? = nil, name: String? = nil, state: ChainState = .active, createdAt: Int = 0,
                closedAt: Int? = nil, members: [ChainMember] = [], parent: String? = nil) {
        self.slug = slug
        self.id = id ?? slug
        self.name = name ?? slug
        self.state = state
        self.createdAt = createdAt
        self.closedAt = closedAt
        self.members = members
        self.parent = parent
    }

    private enum CodingKeys: String, CodingKey {
        case slug, id, name, state, createdAt, closedAt, members, parent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? slug
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
        state = try c.decode(ChainState.self, forKey: .state)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        closedAt = try c.decodeIfPresent(Int.self, forKey: .closedAt)
        members = try c.decode([ChainMember].self, forKey: .members)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
    }

    /// `closedAt` is written as null rather than omitted while the chain is active,
    /// which is what the daemon sends: one shape for the same chain on either side.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(closedAt, forKey: .closedAt)
        try c.encode(members, forKey: .members)
        try c.encodeIfPresent(parent, forKey: .parent)
    }
}

/// A client's copy of the daemon's book, kept by applying the frames in order.
///
/// Every frame is whole — a snapshot, one chain, or one removal — so applying one a
/// client already applied changes nothing, and the last frame for a slug is the truth
/// about it. That is what lets a subscriber take the snapshot and the change stream in
/// whatever order they overlap.
public struct ChainBook: Sendable, Equatable {
    /// Oldest first, the daemon's order.
    public private(set) var chains: [Chain]

    public init(_ chains: [Chain] = []) {
        self.chains = chains
    }

    public var isEmpty: Bool { chains.isEmpty }
    public var active: [Chain] { chains.filter(\.isActive) }

    public subscript(slug: String) -> Chain? {
        chains.first { $0.slug == slug }
    }

    /// The chains nested directly under `slug` (juancode-8oa5.9), oldest first.
    public func children(of slug: String) -> [Chain] {
        chains.filter { $0.parent == slug }
    }

    /// `slug` and every chain nested under it, however deep, parents before their
    /// children (juancode-i38u). A parent cycle ends; an unknown slug gives nothing.
    public func subtree(of slug: String) -> [Chain] {
        var seen: Set<String> = [], out: [Chain] = [], queue = [slug]
        while !queue.isEmpty {
            let at = queue.removeFirst()
            guard seen.insert(at).inserted, let chain = self[at] else { continue }
            out.append(chain)
            queue += children(of: at).map(\.slug)
        }
        return out
    }

    /// Whether `chain` nests under a chain this book holds; a parent that is gone
    /// leaves it at the top.
    public func isNested(_ chain: Chain) -> Bool {
        chain.parent.map { self[$0] != nil } ?? false
    }

    /// `roots` with every chain nested under each, depth first, children oldest first,
    /// each with its depth: the rail's outline (juancode-i38u). A parent cycle ends.
    public func outline(_ roots: [Chain]) -> [(chain: Chain, depth: Int)] {
        var seen: Set<String> = [], out: [(chain: Chain, depth: Int)] = []
        func walk(_ chain: Chain, _ depth: Int) {
            guard seen.insert(chain.slug).inserted else { return }
            out.append((chain, depth))
            for child in children(of: chain.slug) { walk(child, depth + 1) }
        }
        for root in roots { walk(root, 0) }
        return out
    }

    /// Every session in `slug` and in each chain nested under it, however deep
    /// (juancode-8oa5.12) — what the chain's token total sums. A parent cycle ends.
    /// Mirrors `chainTokens` in the sidecar's chains.ts.
    public func sessionRefs(under slug: String) -> Set<String> {
        Set(subtree(of: slug).flatMap { $0.members.filter { $0.kind == .session }.map(\.ref) })
    }

    /// The chain an item is in, if any.
    public func chain(of kind: ChainMemberKind, ref: String) -> Chain? {
        chains.first { $0.members.contains { $0.kind == kind && $0.ref == ref } }
    }

    /// The chain a session (agent or Oracle) is in, if any.
    public func chain(forSession sessionId: String) -> Chain? {
        chain(of: .session, ref: sessionId)
    }

    /// Replace the whole book (`chains`).
    public mutating func replace(with chains: [Chain]) {
        self.chains = chains
    }

    /// Replace one chain, or add it at the end (`chain`).
    public mutating func upsert(_ chain: Chain) {
        if let i = chains.firstIndex(where: { $0.slug == chain.slug }) {
            chains[i] = chain
        } else {
            chains.append(chain)
        }
    }

    /// Drop one chain (`chainRemoved`).
    public mutating func remove(slug: String) {
        chains.removeAll { $0.slug == slug }
    }
}
