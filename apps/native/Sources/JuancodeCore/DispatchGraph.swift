import Foundation

/// Read-only DAG of the work in flight (juancode-wn64): bd ticket → Oracle
/// dispatch → session → worktree/branch → PR + its CI state.
///
/// Nothing here reaches for data of its own. Every node and every edge comes from
/// state the app already holds — the bd issue caches, the Oracle dispatch
/// registry, the session registry, the worktree scan, the tracked/open PR lists —
/// so the graph is a *view* of that state and can never disagree with the panels
/// it links to. Pure and value-typed, which is also what makes it testable
/// without an AppModel.
///
/// The one inference this file makes is ticket linkage: a dispatch's prompt (or a
/// session title, or a branch name) mentions the ticket it is working. That is
/// matched against the *known* issue ids of the project, never against a guessed
/// id shape, so an unrelated hyphenated word can't invent a ticket node.

// MARK: - node / edge model

/// What a node stands for. The case order is the column order, left to right —
/// the layered layout is literally this enum.
public enum GraphNodeKind: String, Sendable, Codable, CaseIterable {
    case ticket, dispatch, session, worktree, pr

    /// Column index in the layered layout.
    public var layer: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Column header.
    public var columnTitle: String {
        switch self {
        case .ticket: "Ticket"
        case .dispatch: "Dispatch"
        case .session: "Session"
        case .worktree: "Branch"
        case .pr: "PR / CI"
        }
    }

    public var symbol: String {
        switch self {
        case .ticket: "tag"
        case .dispatch: "paperplane"
        case .session: "terminal"
        case .worktree: "arrow.triangle.branch"
        case .pr: "arrow.triangle.pull"
        }
    }
}

/// A node's roll-up state, which is all the colour the graph needs: green for
/// finished/passing, orange for "wants a human", blue for running, red for
/// failed/blocked, grey for everything at rest.
public enum GraphNodeState: String, Sendable, Codable {
    case running, waiting, done, failed, blocked, idle
}

/// Where clicking a node goes. Resolved by the view against the app's existing
/// jump affordances — this file never navigates.
public enum GraphJump: Sendable, Equatable {
    case session(String)
    case pr(cwd: String, number: Int)
    case ticket(cwd: String, id: String)
}

public struct GraphNode: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: GraphNodeKind
    /// Primary line — the ticket id, the provider, the branch, "#123".
    public var label: String
    /// Secondary line — a title, a path tail, a CI summary.
    public var detail: String
    public var state: GraphNodeState
    /// Optional trailing chip (priority, CI counts, activity).
    public var badge: String?
    /// The project (repo root) this node belongs to, for grouping and headers.
    public var project: String
    public var jump: GraphJump?
    /// Sort key for chain ordering: ms since epoch of the freshest thing behind
    /// this node (0 when unknown).
    public var at: Int
    /// Layout, filled in by `DispatchGraph.layout`.
    public var layer: Int = 0
    public var row: Int = 0

    public init(id: String, kind: GraphNodeKind, label: String, detail: String,
                state: GraphNodeState, badge: String? = nil, project: String,
                jump: GraphJump? = nil, at: Int = 0) {
        self.id = id; self.kind = kind; self.label = label; self.detail = detail
        self.state = state; self.badge = badge; self.project = project
        self.jump = jump; self.at = at
        self.layer = kind.layer
    }
}

public enum GraphEdgeKind: String, Sendable, Codable {
    /// The chain itself: ticket → dispatch → session → branch → PR.
    case flow
    /// A bd relationship between two tickets (parent / blocks).
    case dependency
}

public struct GraphEdge: Identifiable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var kind: GraphEdgeKind
    public var id: String { "\(from)|\(to)|\(kind.rawValue)" }

    public init(from: String, to: String, kind: GraphEdgeKind = .flow) {
        self.from = from; self.to = to; self.kind = kind
    }
}

// MARK: - inputs

/// One bd issue plus the project whose tracker it came from.
public struct GraphIssueInput: Sendable, Equatable {
    public var project: String
    public var issue: BeadsIssue
    public init(project: String, issue: BeadsIssue) {
        self.project = project; self.issue = issue
    }
}

/// One entry of the Oracle dispatch registry (`oracle-dispatches.json`), reduced
/// to what the graph needs.
public struct GraphDispatchInput: Sendable, Equatable {
    public var dispatchId: String
    public var project: String
    public var prompt: String
    public var provider: String
    public var sessionId: String?
    /// "started" / "queued" / "rejected".
    public var outcome: String
    public var at: Int
    public init(dispatchId: String, project: String, prompt: String, provider: String,
                sessionId: String?, outcome: String, at: Int) {
        self.dispatchId = dispatchId; self.project = project; self.prompt = prompt
        self.provider = provider; self.sessionId = sessionId; self.outcome = outcome
        self.at = at
    }
}

/// One session, plus the live bits the meta alone doesn't carry.
public struct GraphSessionInput: Sendable, Equatable {
    public var meta: SessionMeta
    public var activity: SessionActivity?
    public var live: Bool
    /// The checked-out branch of the session's working dir, when the app knows it.
    public var branch: String?
    public init(meta: SessionMeta, activity: SessionActivity? = nil, live: Bool = false,
                branch: String? = nil) {
        self.meta = meta; self.activity = activity; self.live = live; self.branch = branch
    }
}

/// One PR — tracked (with its poller's CI snapshot) or merely open on a session's
/// branch. `sessionId` is set only for tracked PRs, which know their agent.
public struct GraphPrInput: Sendable, Equatable {
    public var cwd: String
    public var number: Int
    public var title: String
    public var branch: String
    public var checks: PrChecks
    public var checkSummary: String?
    /// Under the tracked-PR poller (as opposed to just an open PR we spotted).
    public var tracked: Bool
    /// The tracked PR's agent session.
    public var sessionId: String?
    /// The tracked PR has an outstanding decision for the user.
    public var needsDecision: Bool
    public var at: Int
    public init(cwd: String, number: Int, title: String, branch: String, checks: PrChecks,
                checkSummary: String? = nil, tracked: Bool = false, sessionId: String? = nil,
                needsDecision: Bool = false, at: Int = 0) {
        self.cwd = cwd; self.number = number; self.title = title; self.branch = branch
        self.checks = checks; self.checkSummary = checkSummary; self.tracked = tracked
        self.sessionId = sessionId; self.needsDecision = needsDecision; self.at = at
    }
}

public struct DispatchGraphInput: Sendable, Equatable {
    public var issues: [GraphIssueInput]
    public var dispatches: [GraphDispatchInput]
    public var sessions: [GraphSessionInput]
    public var worktrees: [Worktree]
    public var prs: [GraphPrInput]

    public init(issues: [GraphIssueInput] = [], dispatches: [GraphDispatchInput] = [],
                sessions: [GraphSessionInput] = [], worktrees: [Worktree] = [],
                prs: [GraphPrInput] = []) {
        self.issues = issues; self.dispatches = dispatches; self.sessions = sessions
        self.worktrees = worktrees; self.prs = prs
    }
}

/// The laid-out graph: nodes carrying `(layer, row)` grid coordinates, the edges
/// between them, and the chains (connected components) in display order.
public struct DispatchGraphLayout: Sendable, Equatable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    /// Node ids per chain, in the order the chains are stacked.
    public var chains: [[String]]
    /// Grid extent, so the view can size its canvas.
    public var rowCount: Int
    public var layerCount: Int

    public var isEmpty: Bool { nodes.isEmpty }
    public func node(_ id: String) -> GraphNode? { nodes.first { $0.id == id } }
}

// MARK: - builder

public enum DispatchGraph {
    // Stable node ids, so selection survives a rebuild.
    public static func ticketId(project: String, issue: String) -> String { "ticket:\(project)#\(issue)" }
    public static func dispatchNodeId(_ id: String) -> String { "dispatch:\(id)" }
    public static func sessionNodeId(_ id: String) -> String { "session:\(id)" }
    public static func worktreeNodeId(_ path: String) -> String { "worktree:\(path)" }
    public static func prNodeId(cwd: String, number: Int) -> String { "pr:\(cwd)#\(number)" }

    /// Build the graph, then lay it out. The two halves are separate so tests can
    /// assert on either.
    public static func build(_ input: DispatchGraphInput) -> DispatchGraphLayout {
        var b = Builder(input: input)
        b.run()
        return layout(nodes: b.orderedNodes(), edges: b.edges)
    }

    /// Assign each node a `(layer, row)` grid slot: chains are stacked top to
    /// bottom, and within a chain each column's nodes take consecutive rows from
    /// the chain's base row. Chains are ordered by their freshest timestamp, so
    /// the work that just moved is at the top.
    public static func layout(nodes: [GraphNode], edges: [GraphEdge]) -> DispatchGraphLayout {
        guard !nodes.isEmpty else {
            return DispatchGraphLayout(nodes: [], edges: [], chains: [], rowCount: 0,
                                       layerCount: GraphNodeKind.allCases.count)
        }
        var byId: [String: GraphNode] = [:]
        for n in nodes { byId[n.id] = n }
        // Edges pointing at nodes we didn't build (a pruned ticket, say) would
        // draw into nowhere — drop them here rather than in every consumer.
        let edges = edges.filter { byId[$0.from] != nil && byId[$0.to] != nil }

        // Connected components over the undirected edge set.
        var parent: [String: String] = [:]
        for n in nodes { parent[n.id] = n.id }
        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            var cur = x
            while let p = parent[cur], p != root { parent[cur] = root; cur = p }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for e in edges { union(e.from, e.to) }

        var groups: [String: [GraphNode]] = [:]
        for n in nodes { groups[find(n.id), default: []].append(n) }

        // Freshest first; ties broken by chain size then id so the order is stable.
        let ordered = groups.values.sorted { a, b in
            let fa = a.map(\.at).max() ?? 0, fb = b.map(\.at).max() ?? 0
            if fa != fb { return fa > fb }
            if a.count != b.count { return a.count > b.count }
            return (a.map(\.id).min() ?? "") < (b.map(\.id).min() ?? "")
        }

        var placed: [GraphNode] = []
        var chains: [[String]] = []
        var base = 0
        for chain in ordered {
            var height = 0
            var chainIds: [String] = []
            for kind in GraphNodeKind.allCases {
                let column = chain.filter { $0.kind == kind }
                    .sorted { ($0.label, $0.id) < ($1.label, $1.id) }
                for (offset, node) in column.enumerated() {
                    var n = node
                    n.layer = kind.layer
                    n.row = base + offset
                    placed.append(n)
                    chainIds.append(n.id)
                }
                height = max(height, column.count)
            }
            chains.append(chainIds)
            base += height
        }
        return DispatchGraphLayout(nodes: placed, edges: edges, chains: chains,
                                   rowCount: base, layerCount: GraphNodeKind.allCases.count)
    }

    /// Find the ids in `known` that `text` mentions, as whole tokens, ordered by
    /// where they first appear. Matching against known ids (rather than a guessed
    /// id shape) is what keeps a prose hyphenation from minting a phantom ticket;
    /// the boundary check is what keeps `juancode-wn6` from matching inside
    /// `juancode-wn64`.
    public static func mentionedIds(in text: String, known: [String]) -> [String] {
        guard !text.isEmpty, !known.isEmpty else { return [] }
        let haystack = text.lowercased()
        var hits: [(offset: Int, id: String)] = []
        for id in known {
            let needle = id.lowercased()
            guard !needle.isEmpty else { continue }
            var searchStart = haystack.startIndex
            while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                let beforeOK = range.lowerBound == haystack.startIndex
                    || !isIdCharacter(haystack[haystack.index(before: range.lowerBound)])
                let afterOK = range.upperBound == haystack.endIndex
                    || !isIdCharacter(haystack[range.upperBound])
                if beforeOK && afterOK {
                    hits.append((haystack.distance(from: haystack.startIndex, to: range.lowerBound), id))
                    break
                }
                searchStart = range.upperBound
            }
        }
        return hits.sorted { $0.offset == $1.offset ? $0.id < $1.id : $0.offset < $1.offset }
            .map(\.id)
    }

    /// Characters that can continue an issue id — a hyphen counts, so a longer id
    /// never matches as the prefix of another. A dot does not: an id at the end of
    /// a sentence (or in front of a file extension) is still a mention.
    private static func isIdCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_"
    }
}

// MARK: - builder internals

private struct Builder {
    let input: DispatchGraphInput
    var nodes: [String: GraphNode] = [:]
    var edges: [GraphEdge] = []
    /// Insertion order, so the layout's tie-breaks are deterministic.
    var order: [String] = []

    init(input: DispatchGraphInput) { self.input = input }

    mutating func add(_ node: GraphNode) {
        if nodes[node.id] == nil { order.append(node.id) }
        // A later, fresher sighting of the same node wins its timestamp but keeps
        // the first description (they're built from the same source anyway).
        if let existing = nodes[node.id] {
            nodes[node.id] = existing.at >= node.at ? existing : node
        } else {
            nodes[node.id] = node
        }
    }

    mutating func link(_ from: String, _ to: String, _ kind: GraphEdgeKind = .flow) {
        let e = GraphEdge(from: from, to: to, kind: kind)
        if !edges.contains(e) { edges.append(e) }
    }

    func orderedNodes() -> [GraphNode] { order.compactMap { nodes[$0] } }

    /// Issue lookup, per project. A dispatch to a repo whose tracker we haven't
    /// cached still gets its ticket, via `resolve`'s fallback across projects.
    private func issuesByProject() -> [String: [String: BeadsIssue]] {
        var out: [String: [String: BeadsIssue]] = [:]
        for i in input.issues { out[i.project, default: [:]][i.issue.id] = i.issue }
        return out
    }

    mutating func run() {
        // Locals, not `self.input.…`, so the loops don't read self while the body
        // mutates it.
        let byProject = issuesByProject()
        let known = Set(input.issues.map(\.issue.id)).sorted()
        let sessions = input.sessions
        let worktrees = input.worktrees
        let prs = input.prs
        let dispatches = input.dispatches
        let dispatchesBySession = Dictionary(
            grouping: dispatches.filter { $0.sessionId != nil },
            by: { $0.sessionId! })

        // Sessions are the spine: everything else hangs off one.
        for s in sessions where s.meta.kind == .agent {
            let sid = DispatchGraph.sessionNodeId(s.meta.id)
            let project = projectCwd(for: s.meta.cwd)
            add(sessionNode(s, id: sid, project: project))

            // ── branch / worktree
            let worktree = worktrees.first { same($0.path, s.meta.worktreePath) }
            let branch = worktree?.branch ?? s.branch
            var branchNodeId: String?
            if let path = s.meta.worktreePath {
                let wid = DispatchGraph.worktreeNodeId(path)
                add(GraphNode(
                    id: wid, kind: .worktree,
                    label: branch ?? (path as NSString).lastPathComponent,
                    detail: (path as NSString).lastPathComponent,
                    state: s.live ? .running : .idle,
                    badge: "worktree", project: project,
                    jump: .session(s.meta.id), at: s.meta.updatedAt))
                link(sid, wid)
                branchNodeId = wid
            } else if let branch, !branch.isEmpty {
                // No juancode worktree — the session works a branch in place. Still
                // a real link in the chain, so it gets the same column.
                let wid = DispatchGraph.worktreeNodeId("\(s.meta.cwd)#\(branch)")
                add(GraphNode(
                    id: wid, kind: .worktree, label: branch,
                    detail: (s.meta.cwd as NSString).lastPathComponent,
                    state: s.live ? .running : .idle,
                    badge: "in place", project: project,
                    jump: .session(s.meta.id), at: s.meta.updatedAt))
                link(sid, wid)
                branchNodeId = wid
            }

            // ── PR on that branch (or tracked against this session)
            for pr in prs where matches(pr, session: s, branch: branch) {
                let pid = DispatchGraph.prNodeId(cwd: pr.cwd, number: pr.number)
                add(prNode(pr, id: pid))
                link(branchNodeId ?? sid, pid)
            }

            // ── dispatch that started it
            let own = dispatchesBySession[s.meta.id] ?? []
            for d in own {
                let did = DispatchGraph.dispatchNodeId(d.dispatchId)
                add(dispatchNode(d, id: did, project: project))
                link(did, sid)
                linkTickets(from: promptScanTexts(d.prompt), into: did, project: project,
                            known: known, byProject: byProject, at: d.at)
            }
            // A session with no dispatch record can still name its ticket (a
            // hand-started session on a `<id>` branch, a CLI-derived title).
            if own.isEmpty {
                linkTickets(from: [s.meta.title, branch ?? "", s.meta.worktreePath ?? ""],
                            into: sid, project: project, known: known, byProject: byProject,
                            at: s.meta.updatedAt)
            }
        }

        // Tracked PRs whose session is gone (or was never in the list) still belong
        // in the graph — that PR is work in flight.
        for pr in prs where pr.tracked {
            add(prNode(pr, id: DispatchGraph.prNodeId(cwd: pr.cwd, number: pr.number)))
        }

        // Dispatches that never produced a live session (rejected, still queued, or
        // whose session has since been pruned) are the other half of the story the
        // registry tells.
        let placedSessions = Set(sessions.map { DispatchGraph.sessionNodeId($0.meta.id) })
        for d in dispatches {
            let sessionNode = d.sessionId.map { DispatchGraph.sessionNodeId($0) }
            if let sessionNode, placedSessions.contains(sessionNode) { continue }
            let project = projectCwd(for: d.project)
            let did = DispatchGraph.dispatchNodeId(d.dispatchId)
            add(dispatchNode(d, id: did, project: project))
            linkTickets(from: promptScanTexts(d.prompt), into: did, project: project,
                        known: known, byProject: byProject, at: d.at)
        }
    }

    /// Where to look for a dispatch's ticket, in order: its first line, then its
    /// opening paragraph. A dispatch leads with the work ("Implement bd ticket
    /// <id>: …") and mentions siblings further down ("juancode-x is editing the
    /// same file tonight"), so a hit up top is the work and a hit deep in the body
    /// is context.
    private func promptScanTexts(_ prompt: String) -> [String] {
        let head = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return [head, String(prompt.prefix(400))]
    }

    /// Edge the ticket `text` is about into `target`, and pull in its bd parent as
    /// a dependency edge.
    ///
    /// Only the FIRST id mentioned counts — a dispatch prompt leads with the ticket
    /// it is implementing ("Implement bd ticket <id>: …") and then routinely names
    /// siblings ("juancode-x is editing the same file tonight"). Linking every
    /// mention fused tonight's five independent chains into one blob; the leading
    /// mention is the one that means "this is the work".
    /// `texts` are candidate places to look, best first; the first one that names a
    /// known ticket wins and the rest are ignored.
    private mutating func linkTickets(from texts: [String], into target: String, project: String,
                                      known: [String], byProject: [String: [String: BeadsIssue]],
                                      at: Int) {
        let mentions = texts.lazy
            .map { DispatchGraph.mentionedIds(in: $0, known: known) }
            .first { !$0.isEmpty } ?? []
        for id in mentions.prefix(1) {
            guard let (owner, issue) = resolve(id, project: project, byProject: byProject) else { continue }
            let tid = DispatchGraph.ticketId(project: owner, issue: issue.id)
            add(ticketNode(issue, id: tid, project: owner, at: at))
            link(tid, target)
            // bd's cached listing carries only the parent link, not the full
            // dependency ids — see the follow-up on the ticket.
            if let parentId = issue.parent, let (powner, parent) = resolve(parentId, project: owner, byProject: byProject) {
                let pid = DispatchGraph.ticketId(project: powner, issue: parent.id)
                add(ticketNode(parent, id: pid, project: powner, at: at))
                link(pid, tid, .dependency)
            }
        }
    }

    /// The project whose tracker owns `id`, preferring the session's own project.
    private func resolve(_ id: String, project: String,
                         byProject: [String: [String: BeadsIssue]]) -> (String, BeadsIssue)? {
        if let hit = byProject[project]?[id] { return (project, hit) }
        for (owner, issues) in byProject.sorted(by: { $0.key < $1.key }) {
            if let hit = issues[id] { return (owner, hit) }
        }
        return nil
    }

    private func matches(_ pr: GraphPrInput, session s: GraphSessionInput, branch: String?) -> Bool {
        if let sid = pr.sessionId, sid == s.meta.id { return true }
        guard let branch, !branch.isEmpty, pr.branch == branch else { return false }
        return same(pr.cwd, projectCwd(for: s.meta.cwd)) || same(pr.cwd, s.meta.cwd)
    }

    private func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a == b || (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    // MARK: node constructors

    private func sessionNode(_ s: GraphSessionInput, id: String, project: String) -> GraphNode {
        let state: GraphNodeState
        if s.meta.status == .exited { state = s.meta.dormant ? .idle : .done }
        else if s.activity == .waitingInput { state = .waiting }
        else if s.activity == .busy { state = .running }
        else { state = .idle }
        let badge: String?
        switch s.activity {
        case .busy: badge = "busy"
        case .waitingInput: badge = "needs input"
        case .idle: badge = s.live ? "idle" : nil
        case nil: badge = s.meta.dormant ? "sleeping" : nil
        }
        let title = s.meta.title.isEmpty ? s.meta.id.prefix(8) + "…" : Substring(s.meta.title)
        return GraphNode(
            id: id, kind: .session, label: s.meta.provider.rawValue, detail: String(title),
            state: state, badge: badge, project: project,
            jump: .session(s.meta.id), at: s.meta.updatedAt)
    }

    private func dispatchNode(_ d: GraphDispatchInput, id: String, project: String) -> GraphNode {
        let state: GraphNodeState
        switch d.outcome {
        case "rejected": state = .failed
        case "queued": state = .waiting
        default: state = d.sessionId == nil ? .idle : .done
        }
        return GraphNode(
            id: id, kind: .dispatch, label: d.provider.isEmpty ? "dispatch" : d.provider,
            detail: firstLine(d.prompt), state: state, badge: d.outcome,
            project: project, jump: d.sessionId.map { .session($0) }, at: d.at)
    }

    private func ticketNode(_ issue: BeadsIssue, id: String, project: String, at: Int) -> GraphNode {
        let state: GraphNodeState
        let status = issue.status.lowercased()
        if status == "closed" || status == "done" { state = .done }
        else if issue.blocked { state = .blocked }
        else if status.contains("progress") { state = .running }
        else if issue.ready { state = .idle }
        else { state = .idle }
        return GraphNode(
            id: id, kind: .ticket, label: issue.id, detail: issue.title, state: state,
            badge: "p\(issue.priority)", project: project,
            jump: .ticket(cwd: project, id: issue.id), at: at)
    }

    private func prNode(_ pr: GraphPrInput, id: String) -> GraphNode {
        let state: GraphNodeState
        if pr.needsDecision { state = .waiting }
        else {
            switch pr.checks {
            case .failing: state = .failed
            case .passing: state = .done
            case .pending: state = .running
            case .none: state = .idle
            }
        }
        let ci = pr.checkSummary ?? ciLabel(pr.checks)
        return GraphNode(
            id: id, kind: .pr, label: "#\(pr.number)", detail: pr.title, state: state,
            badge: pr.needsDecision ? "needs decision" : ci,
            project: pr.cwd, jump: .pr(cwd: pr.cwd, number: pr.number), at: pr.at)
    }

    private func ciLabel(_ checks: PrChecks) -> String {
        switch checks {
        case .passing: "CI green"
        case .failing: "CI red"
        case .pending: "CI running"
        case .none: "no CI"
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}
