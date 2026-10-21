import Foundation

/// A chain member's identity without its snapshot fields: what the chain view selects,
/// remembers per chain, and compares across book updates (a member's `title` may
/// change under it while it stays the same tab).
public struct ChainMemberRef: Hashable, Sendable {
    public var kind: ChainMemberKind
    public var ref: String

    public init(kind: ChainMemberKind, ref: String) {
        self.kind = kind
        self.ref = ref
    }

    /// The string form a remembered tab is persisted as: `<kind>:<ref>`.
    public var key: String { "\(kind.rawValue):\(ref)" }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":"),
              let kind = ChainMemberKind(rawValue: String(key[..<colon]))
        else { return nil }
        let ref = String(key[key.index(after: colon)...])
        guard !ref.isEmpty else { return nil }
        self.init(kind: kind, ref: ref)
    }
}

extension ChainMember {
    public var memberRef: ChainMemberRef { ChainMemberRef(kind: kind, ref: ref) }
}

extension Chain {
    public func contains(_ member: ChainMemberRef) -> Bool {
        members.contains { $0.kind == member.kind && $0.ref == member.ref }
    }

    public func member(_ member: ChainMemberRef) -> ChainMember? {
        members.first { $0.kind == member.kind && $0.ref == member.ref }
    }

    func index(of member: ChainMemberRef) -> Int? {
        members.firstIndex { $0.kind == member.kind && $0.ref == member.ref }
    }
}

/// Which tab the chain view shows, as pure decisions over a `Chain` so the app's
/// open/exit/step paths and a book update all agree. Tabs are the members in the
/// order they joined.
public enum ChainTabs {
    /// The tab opening `chain` lands on: the member asked for, else the one last
    /// viewed in this chain, else the session already on screen when it is a member
    /// (opening your own session's chain should not move you), else the first.
    /// Nil only for an empty chain.
    public static func landing(in chain: Chain, asked: ChainMemberRef?,
                               remembered: ChainMemberRef?, showing: String?) -> ChainMemberRef? {
        if let asked, chain.contains(asked) { return asked }
        if let remembered, chain.contains(remembered) { return remembered }
        if let showing {
            let session = ChainMemberRef(kind: .session, ref: showing)
            if chain.contains(session) { return session }
        }
        return chain.members.first?.memberRef
    }

    /// The tab `offset` places from `current`, wrapping at both ends. From no tab (or
    /// one no longer in the chain), forward lands on the first and back on the last.
    public static func step(in chain: Chain, from current: ChainMemberRef?,
                            by offset: Int) -> ChainMemberRef? {
        let count = chain.members.count
        guard count > 0 else { return nil }
        guard let current, let i = chain.index(of: current) else {
            return (offset >= 0 ? chain.members.first : chain.members.last)?.memberRef
        }
        let next = ((i + offset) % count + count) % count
        return chain.members[next].memberRef
    }

    /// The tab to show after the chain changed under the view: the same one while it
    /// is still a member, else whichever member now sits where it was (so untagging
    /// the open tab lands on its neighbour, not back at the start), else nil.
    public static func reconcile(_ current: ChainMemberRef?, old: Chain?,
                                 new: Chain) -> ChainMemberRef? {
        guard !new.members.isEmpty else { return nil }
        guard let current else { return new.members.first?.memberRef }
        if new.contains(current) { return current }
        let was = old?.index(of: current) ?? 0
        return new.members[min(was, new.members.count - 1)].memberRef
    }
}
