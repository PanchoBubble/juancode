import Foundation

/// What a chain's members are waiting on you for: sessions (agents and Oracles) that
/// stopped at a prompt, and tracked PRs with an open decision. The Chains rail panel
/// draws it on each row, and its header sums it, so a chain that needs you is visible
/// without opening it.
///
/// The book does not know live state, so the caller answers it per ref: whether a
/// session is waiting for input, and whether a tracked PR needs a decision.
public struct ChainAttention: Equatable, Sendable {
    public var waitingInput: Int
    public var needsDecision: Int

    public init(waitingInput: Int = 0, needsDecision: Int = 0) {
        self.waitingInput = waitingInput
        self.needsDecision = needsDecision
    }

    public init(_ chain: Chain, waiting: (String) -> Bool, deciding: (String) -> Bool) {
        self.init(
            waitingInput: chain.members.filter { $0.kind == .session && waiting($0.ref) }.count,
            needsDecision: chain.members.filter { $0.kind == .trackedPr && deciding($0.ref) }.count)
    }

    public var total: Int { waitingInput + needsDecision }
    public var isEmpty: Bool { total == 0 }
}

extension ChainBook {
    /// Closed chains, most recently closed first: the ones you are likeliest to reopen.
    public var inactive: [Chain] {
        chains.filter { !$0.isActive }.sorted { ($0.closedAt ?? 0) > ($1.closedAt ?? 0) }
    }
}
