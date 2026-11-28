import Foundation
import CoreGraphics

/// The chain graph's decisions (juancode-043.8): which nodes a chain draws, which
/// connections join them, how they fall into groups, and where everything sits.
///
/// A connection is drawn only for a relationship something actually recorded: a
/// daemon handoff (source owner → target owner), the Beads issue a handoff names, a
/// tracked PR's watching session, a tracked Linear ticket's session. Being in the same
/// chain is NOT a relationship — it says the items belong together, not that one
/// depends on, owns or follows another — so members with no recorded link are drawn
/// as their own, visibly unconnected group. Nothing here matches titles, branches or
/// prompts to guess a link.
///
/// Pure over a `Chain`, its handoffs and the links the app read off its own records,
/// so the graph is tested without a model or a view.

/// One node: a chain member, the human end of a handoff, a session a handoff names
/// that is not (or no longer) in this chain, or a chain nested under this one, drawn
/// collapsed (juancode-i38u).
public enum ChainGraphNodeID: Hashable, Sendable {
    case member(ChainMemberRef)
    case human
    case outsideSession(String)
    case chain(String)

    public var key: String {
        switch self {
        case let .member(ref): return "member:\(ref.key)"
        case .human: return "human"
        case let .outsideSession(id): return "outside:\(id)"
        case let .chain(slug): return "chain:\(slug)"
        }
    }
}

/// What recorded a connection.
public enum ChainGraphEdgeKind: Equatable, Sendable {
    /// A daemon handoff record, source owner → target owner.
    case handoff(ChainHandoff)
    /// The Beads issue a handoff names, when that issue is a member: handoff target →
    /// ticket. Carries the handoff it came from.
    case handoffIssue(ChainHandoff)
    /// A tracked PR's watch names the session working it: session → PR.
    case watchesPr
    /// A tracked Linear ticket names the session working it: session → ticket.
    case tracksTicket
    /// A nested chain's sub-orchestrator names this member as the session that
    /// dispatched it (its `parentSessionId`): session → nested chain.
    case dispatchesChain
    /// A session dispatched another (the child's `parentSessionId`): parent → child.
    case dispatched

    public var title: String {
        switch self {
        case .handoff: return "Handoff"
        case .handoffIssue: return "Handoff issue"
        case .watchesPr: return "Watches PR"
        case .tracksTicket: return "Tracks ticket"
        case .dispatchesChain: return "Dispatched chain"
        case .dispatched: return "Dispatched"
        }
    }
}

/// An explicit non-handoff link the app read off its own records (a tracked PR's or
/// tracked ticket's session). `ChainGraph.build` drops one whose ends are not both
/// members, so a stale record cannot draw into the chain.
public struct ChainGraphLink: Equatable, Sendable {
    public var from: ChainMemberRef
    public var to: ChainMemberRef
    public var kind: ChainGraphEdgeKind

    public init(from: ChainMemberRef, to: ChainMemberRef, kind: ChainGraphEdgeKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}

/// A chain nested directly under the graphed one, and the session that dispatched its
/// orchestrator, as that session recorded it. `ChainGraph.build` draws the edge only
/// when the dispatcher is a session member of the graphed chain.
public struct ChainGraphSubchain: Equatable, Sendable {
    public var slug: String
    public var dispatcher: String?

    public init(slug: String, dispatcher: String?) {
        self.slug = slug
        self.dispatcher = dispatcher
    }
}

public struct ChainGraphEdge: Equatable, Sendable, Identifiable {
    public var id: String
    public var from: ChainGraphNodeID
    public var to: ChainGraphNodeID
    public var kind: ChainGraphEdgeKind

    /// The short label drawn on the connection.
    public var label: String {
        switch kind {
        case let .handoff(h):
            return h.summary.isEmpty ? "Handoff" : h.summary
        case let .handoffIssue(h): return h.beadsIssue ?? "Issue"
        case .watchesPr: return "watches"
        case .tracksTicket: return "tracks"
        case .dispatchesChain: return "dispatched"
        case .dispatched: return "dispatched"
        }
    }

    /// The handoff behind it, for either handoff kind.
    public var handoff: ChainHandoff? {
        switch kind {
        case let .handoff(h), let .handoffIssue(h): return h
        case .watchesPr, .tracksTicket, .dispatchesChain, .dispatched: return nil
        }
    }

    /// An open handoff is the one somebody still has to act on.
    public var isOpen: Bool {
        if case let .handoff(h) = kind { return h.isOpen }
        return false
    }
}

/// A connected group: nodes joined by at least one recorded edge, in columns from the
/// first sender to the last receiver.
public struct ChainGraphGroup: Equatable, Sendable, Identifiable {
    /// Columns left to right; each column's nodes top to bottom.
    public var columns: [[ChainGraphNodeID]]
    public var edges: [ChainGraphEdge]

    public var id: String { columns.first?.first?.key ?? "empty" }
    public var nodes: [ChainGraphNodeID] { columns.flatMap { $0 } }
}

public struct ChainGraph: Equatable, Sendable {
    public var groups: [ChainGraphGroup]
    /// Members with no recorded relationship, in the order they joined.
    public var unconnected: [ChainGraphNodeID]

    public var edges: [ChainGraphEdge] { groups.flatMap(\.edges) }
    public var hasRelationships: Bool { !groups.isEmpty }
    public var isEmpty: Bool { groups.isEmpty && unconnected.isEmpty }

    /// Build the graph for `chain`. `handoffs` may include other chains' records; only
    /// this chain's are used. `links` are the app's explicit non-handoff links;
    /// `subchains` the chains nested directly under it, each one node after the members.
    /// `handoffsShareRank` keeps a handoff's target on its source's rank, right after it,
    /// so a goal passed along reads sideways while dispatches step down (the ↓ layout).
    public static func build(chain: Chain, handoffs: [ChainHandoff],
                             links: [ChainGraphLink] = [],
                             subchains: [ChainGraphSubchain] = [],
                             handoffsShareRank: Bool = false) -> ChainGraph {
        let memberIds = chain.members.map { ChainGraphNodeID.member($0.memberRef) }
            + subchains.map { ChainGraphNodeID.chain($0.slug) }
        let memberSet = Set(memberIds)
        func node(_ owner: ChainHandoffOwner) -> ChainGraphNodeID {
            switch owner {
            case .human: return .human
            case let .session(id):
                let ref = ChainMemberRef(kind: .session, ref: id)
                return chain.contains(ref) ? .member(ref) : .outsideSession(id)
            }
        }

        var edges: [ChainGraphEdge] = []
        let mine = handoffs.filter { $0.chainSlug == chain.slug }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        for h in mine {
            let from = node(h.source), to = node(h.target)
            edges.append(ChainGraphEdge(id: "handoff:\(h.id)", from: from, to: to, kind: .handoff(h)))
            if let issue = h.beadsIssue {
                let ticket = ChainMemberRef(kind: .beads, ref: issue)
                if chain.contains(ticket) {
                    edges.append(ChainGraphEdge(id: "issue:\(h.id)", from: to, to: .member(ticket),
                                                kind: .handoffIssue(h)))
                }
            }
        }
        var seenLinks = Set<String>()
        for link in links where chain.contains(link.from) && chain.contains(link.to) && link.from != link.to {
            let id = "link:\(link.kind.title):\(link.from.key)->\(link.to.key)"
            guard seenLinks.insert(id).inserted else { continue }
            edges.append(ChainGraphEdge(id: id, from: .member(link.from), to: .member(link.to), kind: link.kind))
        }

        for sub in subchains {
            guard let from = sub.dispatcher,
                  chain.contains(ChainMemberRef(kind: .session, ref: from)) else { continue }
            let ref = ChainMemberRef(kind: .session, ref: from)
            edges.append(ChainGraphEdge(id: "subchain:\(sub.slug)", from: .member(ref),
                                        to: .chain(sub.slug), kind: .dispatchesChain))
        }

        // Every node in join order: members first, then the extra ends handoffs named.
        var order = memberIds
        for e in edges {
            for n in [e.from, e.to] where !memberSet.contains(n) && !order.contains(n) { order.append(n) }
        }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        // Connected components over the recorded edges.
        var parent = Array(order.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var touched = Set<Int>()
        for e in edges {
            guard let a = index[e.from], let b = index[e.to] else { continue }
            touched.insert(a); touched.insert(b)
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var componentNodes: [Int: [ChainGraphNodeID]] = [:]
        for i in order.indices where touched.contains(i) {
            componentNodes[find(i), default: []].append(order[i])
        }
        let groups = componentNodes.keys.sorted().map { root -> ChainGraphGroup in
            let nodes = componentNodes[root] ?? []
            let inGroup = Set(nodes)
            let groupEdges = edges.filter { inGroup.contains($0.from) }
            return ChainGraphGroup(columns: columns(nodes, edges: groupEdges, handoffsShareRank: handoffsShareRank),
                                   edges: groupEdges)
        }
        let unconnected = order.indices.filter { !touched.contains($0) }.map { order[$0] }
        return ChainGraph(groups: groups, unconnected: unconnected)
    }

    /// Longest-path columns over the group's edges, ignoring self-loops and any edge
    /// that would close a cycle (a handoff back to an earlier owner still draws, it just
    /// does not push its target right). Within a column, nodes keep join order.
    static func columns(_ nodes: [ChainGraphNodeID], edges: [ChainGraphEdge],
                        handoffsShareRank: Bool = false) -> [[ChainGraphNodeID]] {
        var rank = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        // Forward edges only: an edge counts when its source is reachable before its
        // target in a DFS from the first node in join order, which drops back edges.
        // `step` is how many ranks the edge moves its target: 0 for a sideways handoff.
        var forward: [ChainGraphNodeID: [(to: ChainGraphNodeID, step: Int)]] = [:]
        for e in edges where e.from != e.to {
            var sideways = false
            if handoffsShareRank, case .handoff = e.kind { sideways = true }
            forward[e.from, default: []].append((e.to, sideways ? 0 : 1))
        }
        var state: [ChainGraphNodeID: Int] = [:]  // 1 = on stack, 2 = done
        var dag: [(ChainGraphNodeID, ChainGraphNodeID, Int)] = []
        func visit(_ n: ChainGraphNodeID) {
            state[n] = 1
            for (m, step) in forward[n] ?? [] {
                switch state[m] {
                case 1: continue  // back edge
                case 2: dag.append((n, m, step))
                default:
                    dag.append((n, m, step))
                    visit(m)
                }
            }
            state[n] = 2
        }
        // Start from nodes nothing points at, so the first sender lands in column 0.
        let targets = Set(edges.filter { $0.from != $0.to }.map(\.to))
        for n in nodes where !targets.contains(n) && state[n] == nil { visit(n) }
        for n in nodes where state[n] == nil { visit(n) }
        // Relax in DAG order; bounded by the node count since there are no cycles left.
        for _ in 0..<max(nodes.count, 1) {
            var changed = false
            for (a, b, step) in dag where rank[b, default: 0] < rank[a, default: 0] + step {
                rank[b] = rank[a, default: 0] + step
                changed = true
            }
            if !changed { break }
        }
        // A sideways handoff's target follows its source within the rank (first one wins).
        var after: [ChainGraphNodeID: [ChainGraphNodeID]] = [:]
        var placedAfter = Set<ChainGraphNodeID>()
        for n in nodes {
            for (a, b, step) in dag where step == 0 && b == n && rank[a] == rank[b] {
                after[a, default: []].append(b)
                placedAfter.insert(b)
                break
            }
        }
        let width = (rank.values.max() ?? 0) + 1
        var columns = Array(repeating: [ChainGraphNodeID](), count: width)
        func emit(_ n: ChainGraphNodeID) {
            columns[rank[n, default: 0]].append(n)
            for m in after[n] ?? [] { emit(m) }
        }
        for n in nodes where !placedAfter.contains(n) { emit(n) }
        return columns.filter { !$0.isEmpty }
    }
}

// MARK: - Geometry

/// Card and spacing sizes the layout places with. The view passes its own, so the
/// pure layout and the drawn cards cannot disagree.
public struct ChainGraphMetrics: Equatable, Sendable {
    public var card: CGSize
    public var columnGap: CGFloat
    public var rowGap: CGFloat
    public var groupPadding: CGFloat
    public var groupHeader: CGFloat
    public var groupGap: CGFloat

    /// How much of each earlier card shows when a handoff run stacks (the ↓ layout).
    public var stackPeek: CGFloat

    public init(card: CGSize = CGSize(width: 228, height: 96), columnGap: CGFloat = 112,
                rowGap: CGFloat = 28, groupPadding: CGFloat = 16, groupHeader: CGFloat = 26,
                groupGap: CGFloat = 22, stackPeek: CGFloat = 40) {
        self.card = card
        self.stackPeek = stackPeek
        self.columnGap = columnGap
        self.rowGap = rowGap
        self.groupPadding = groupPadding
        self.groupHeader = groupHeader
        self.groupGap = groupGap
    }
}

/// Where everything is drawn, in one canvas coordinate space.
public struct ChainGraphPlacement: Equatable, Sendable {
    public struct Box: Equatable, Sendable {
        /// The group's index in `ChainGraph.groups`, or nil for the unconnected group.
        public var group: Int?
        public var frame: CGRect
    }

    public var nodes: [ChainGraphNodeID: CGRect]
    public var boxes: [Box]
    public var size: CGSize
    /// Groups flow top to bottom (ranks are rows) instead of left to right.
    public var vertical = false

    /// Connected groups stack top to bottom, each laid out left to right by column
    /// (or, `vertical`, top to bottom by rank with siblings side by side); the unconnected members wrap into as many columns as `width` holds (at least
    /// one), so a narrow window scrolls down rather than sideways where it can.
    public static func place(_ graph: ChainGraph, metrics m: ChainGraphMetrics,
                             width: CGFloat, vertical: Bool = false) -> ChainGraphPlacement {
        var nodes: [ChainGraphNodeID: CGRect] = [:]
        var boxes: [Box] = []
        var y: CGFloat = 0
        var maxX: CGFloat = 0
        let stepX = m.card.width + m.columnGap
        let stepY = m.card.height + m.rowGap

        for (gi, group) in graph.groups.enumerated() where vertical {
            // A card a handoff passed straight on from the card before it stacks over that
            // card, leaving a `stackPeek` strip, so a goal's run of owners stays narrow.
            let handedOn = Set(group.edges.compactMap { e -> String? in
                if case .handoff = e.kind { return "\(e.from.key)>\(e.to.key)" }
                return nil
            })
            let xs = group.columns.map { rank -> (offsets: [CGFloat], width: CGFloat) in
                var offsets: [CGFloat] = []
                var x: CGFloat = 0
                for (i, n) in rank.enumerated() {
                    if i > 0 {
                        x += handedOn.contains("\(rank[i - 1].key)>\(n.key)")
                            ? m.stackPeek : m.card.width + m.rowGap
                    }
                    offsets.append(x)
                }
                return (offsets, rank.isEmpty ? 0 : x + m.card.width)
            }
            let innerW = xs.map(\.width).max() ?? m.card.width
            let top = y + m.groupHeader + m.groupPadding
            let stepRank = m.card.height + m.columnGap
            for (ri, rank) in group.columns.enumerated() {
                // Narrower ranks centre against the widest one.
                let offset = (innerW - xs[ri].width) / 2
                for (si, n) in rank.enumerated() {
                    nodes[n] = CGRect(x: m.groupPadding + offset + xs[ri].offsets[si],
                                      y: top + CGFloat(ri) * stepRank,
                                      width: m.card.width, height: m.card.height)
                }
            }
            let ranks = CGFloat(group.columns.count)
            let w = 2 * m.groupPadding + innerW
            let h = m.groupHeader + 2 * m.groupPadding + ranks * m.card.height + max(ranks - 1, 0) * m.columnGap
            boxes.append(Box(group: gi, frame: CGRect(x: 0, y: y, width: w, height: h)))
            maxX = max(maxX, w)
            y += h + m.groupGap
        }

        for (gi, group) in graph.groups.enumerated() where !vertical {
            let rows = group.columns.map(\.count).max() ?? 1
            let innerH = CGFloat(rows) * m.card.height + CGFloat(max(rows - 1, 0)) * m.rowGap
            // Self-loops draw above their card; leave room in the header band.
            let top = y + m.groupHeader + m.groupPadding
            for (ci, column) in group.columns.enumerated() {
                // Shorter columns centre against the tallest one.
                let colH = CGFloat(column.count) * m.card.height + CGFloat(max(column.count - 1, 0)) * m.rowGap
                let offset = (innerH - colH) / 2
                for (ri, n) in column.enumerated() {
                    nodes[n] = CGRect(x: m.groupPadding + CGFloat(ci) * stepX,
                                      y: top + offset + CGFloat(ri) * stepY,
                                      width: m.card.width, height: m.card.height)
                }
            }
            let cols = CGFloat(group.columns.count)
            let w = 2 * m.groupPadding + cols * m.card.width + max(cols - 1, 0) * m.columnGap
            let h = m.groupHeader + 2 * m.groupPadding + innerH
            boxes.append(Box(group: gi, frame: CGRect(x: 0, y: y, width: w, height: h)))
            maxX = max(maxX, w)
            y += h + m.groupGap
        }

        if !graph.unconnected.isEmpty {
            let gridGap: CGFloat = 14
            // The viewport's width, not the connected groups': those may scroll sideways,
            // but a grid with no edges never needs to.
            let usable = width - 2 * m.groupPadding
            let perRow = max(1, Int((usable + gridGap) / (m.card.width + gridGap)))
            let cols = min(perRow, graph.unconnected.count)
            let rows = (graph.unconnected.count + cols - 1) / cols
            let top = y + m.groupHeader + m.groupPadding
            for (i, n) in graph.unconnected.enumerated() {
                nodes[n] = CGRect(x: m.groupPadding + CGFloat(i % cols) * (m.card.width + gridGap),
                                  y: top + CGFloat(i / cols) * (m.card.height + gridGap),
                                  width: m.card.width, height: m.card.height)
            }
            let w = 2 * m.groupPadding + CGFloat(cols) * m.card.width + CGFloat(cols - 1) * gridGap
            let h = m.groupHeader + 2 * m.groupPadding + CGFloat(rows) * m.card.height
                + CGFloat(rows - 1) * gridGap
            boxes.append(Box(group: nil, frame: CGRect(x: 0, y: y, width: w, height: h)))
            maxX = max(maxX, w)
            y += h + m.groupGap
        }
        return ChainGraphPlacement(nodes: nodes, boxes: boxes,
                                   size: CGSize(width: maxX, height: max(y - m.groupGap, 0)),
                                   vertical: vertical)
    }
}
