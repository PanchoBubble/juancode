import SwiftUI
import JuancodeCore
import JuancodeServices

/// The dispatch-chain graph (juancode-wn64): a read-only DAG of the work in
/// flight — bd ticket → Oracle dispatch → session → branch/worktree → PR and its
/// CI state — laid out in columns, one chain per row band.
///
/// It authors nothing. Every node is state the app already holds (the bd issue
/// caches, the sidecar's dispatch registry, the session registry, the worktree
/// scan, the tracked/open PR lists) and every edge is a link that already exists;
/// `DispatchGraph` in JuancodeCore does the pure assembly and layout, this file
/// only draws it and routes a click to the panel that owns the thing clicked.
///
/// Live without a poll: the graph is rebuilt from `graphSignature`, which reads
/// the same observable session/activity/tracked-PR state the grid renders from,
/// so an agent going busy or a PR going red re-renders this the same frame it
/// re-renders the grid. The dispatch registry is a file, so it is read on open
/// and on the refresh button — never on a timer.
struct DispatchGraphPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The laid-out graph. Built off the main actor into this state, keyed by
    /// `graphSignature`.
    @State private var graph = DispatchGraph.layout(nodes: [], edges: [])
    /// The sidecar's dispatch registry, read from disk on open / refresh.
    @State private var registry: [OracleDispatchRecord] = []
    @State private var selected: String?
    /// Hide work that has gone quiet (exited sessions, day-old dispatches).
    @AppStorage("dispatchGraph.liveOnly") private var liveOnly = true

    private static let staleWindowMs = 24 * 60 * 60 * 1000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let node = selected.flatMap({ graph.node($0) }) {
                Divider()
                DispatchGraphDetail(node: node) { jump(node) }
            }
        }
        .frame(width: 1000, height: 660)
        .task { await prime() }
        // Rebuilt on the same state the grid re-renders from — no timer.
        .task(id: graphSignature) { await rebuild() }
    }

    // MARK: - chrome

    private var header: some View {
        HStack(spacing: 10) {
            Text("Dispatch chains").font(.title3).bold()
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            GraphLegend()
            Toggle("Live only", isOn: $liveOnly)
                .toggleStyle(.button).controlSize(.small).font(.system(size: 10))
                .help("Hide exited sessions and dispatches older than a day")
                .clickCursor()
            Button { Task { await prime() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-read the dispatch registry, issues, worktrees and PRs")
                .clickCursor()
            Button("Done") { dismiss() }.clickCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        guard !graph.isEmpty else { return "" }
        let chains = graph.chains.count
        return "\(chains) chain\(chains == 1 ? "" : "s") · \(graph.nodes.count) nodes"
    }

    @ViewBuilder private var content: some View {
        if graph.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("No work in flight.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Dispatch a ticket, or track a PR, and its chain shows up here.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeaders
                    canvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var columnHeaders: some View {
        ZStack(alignment: .topLeading) {
            ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    Image(systemName: kind.symbol).font(.system(size: 9))
                    Text(kind.columnTitle.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(width: GraphGeometry.nodeW, alignment: .leading)
                .position(x: GraphGeometry.x(kind.layer), y: 11)
            }
        }
        .frame(width: canvasWidth, height: 22, alignment: .topLeading)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for edge in graph.edges {
                    guard let from = graph.node(edge.from), let to = graph.node(edge.to) else { continue }
                    ctx.stroke(GraphGeometry.path(from: from, to: to, kind: edge.kind),
                               with: .color(edgeColor(edge)),
                               style: edge.kind == .dependency
                                   ? StrokeStyle(lineWidth: 1, dash: [3, 3])
                                   : StrokeStyle(lineWidth: 1.2))
                }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            ForEach(graph.nodes) { node in
                GraphNodeCard(node: node, selected: node.id == selected)
                    .frame(width: GraphGeometry.nodeW, height: GraphGeometry.nodeH)
                    .position(x: GraphGeometry.x(node.layer), y: GraphGeometry.y(node.row))
                    .onTapGesture { selected = node.id == selected ? nil : node.id }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
        .padding(.bottom, 12)
    }

    private func edgeColor(_ edge: GraphEdge) -> Color {
        let touchesSelection = selected != nil && (edge.from == selected || edge.to == selected)
        if touchesSelection { return .accentColor.opacity(0.9) }
        return .secondary.opacity(edge.kind == .dependency ? 0.35 : 0.5)
    }

    private var canvasWidth: CGFloat {
        GraphGeometry.pad * 2 + CGFloat(graph.layerCount) * GraphGeometry.colStride
    }
    private var canvasHeight: CGFloat {
        GraphGeometry.pad * 2 + CGFloat(max(graph.rowCount, 1)) * GraphGeometry.rowStride
    }

    // MARK: - clicks

    /// Route a node to the panel that owns it: the session pane, the GitHub PR
    /// view, or the project's issue panel.
    private func jump(_ node: GraphNode) {
        switch node.jump {
        case .session(let id):
            model.selection = id
            model.flashFocusRim()
            dismiss()
        case .pr(let cwd, let number):
            if let t = model.trackedPr(cwd: cwd, number: number) {
                model.openGitHubForTrackedPr(t)
            } else if let pr = model.prs(cwd)?.prs.first(where: { $0.number == number }) {
                model.github.select(cwd: cwd, pr: pr)
                model.openGitHub(scope: cwd)
            } else {
                model.openGitHub(scope: cwd)
            }
            dismiss()
        case .ticket(let cwd, _):
            // bd issues live in the session side panel's Issues tab, so "jump to the
            // ticket" means: land on a session in that project with that tab up.
            guard let session = latestSession(inProject: cwd) else { return }
            UserDefaults.standard.set("Issues", forKey: "session.sidePanel.tab")
            UserDefaults.standard.set(true, forKey: "session.sidePanel.shown")
            model.loadBeads(session.cwd)
            model.selection = session.id
            model.flashFocusRim()
            dismiss()
        case nil:
            break
        }
    }

    private func latestSession(inProject project: String) -> SessionMeta? {
        model.sessions
            .filter { !$0.archived && $0.kind == .agent && projectCwd(for: $0.cwd) == project }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - inputs

    /// Everything the graph reads that changes on its own — session identity,
    /// activity, worktree, the tracked-PR list, the loaded PR/issue caches. Reading
    /// it inside a `.task(id:)` is what makes the panel live: the same observable
    /// state the grid re-renders from re-keys the rebuild.
    private var graphSignature: String {
        var parts: [String] = []
        for meta in model.sessions where meta.kind == .agent {
            parts.append("\(meta.id):\(meta.updatedAt):\(meta.status.rawValue)"
                + ":\(model.activity(meta.id)?.rawValue ?? "-"):\(meta.worktreePath ?? "-")")
        }
        for t in model.trackedList {
            parts.append("pr:\(t.id):\(t.snapshot.checks.rawValue):\(t.notifications.count)")
        }
        parts.append("reg:\(registry.count)")
        parts.append("live:\(liveOnly)")
        parts.append("wt:\(model.worktreeGroups.flatMap(\.children).count)")
        parts.append("bd:\(beadsSignature)")
        return parts.joined(separator: "|")
    }

    private var beadsSignature: String {
        projects.map { "\($0):\(model.beads($0)?.issues.count ?? -1)" }.joined(separator: ",")
    }

    /// Repo roots of the sessions in play — the projects whose issues and PRs the
    /// graph reads.
    private var projects: [String] {
        Array(Set(model.sessions.filter { $0.kind == .agent }.map { projectCwd(for: $0.cwd) })).sorted()
    }

    private func buildInput() -> DispatchGraphInput {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let fresh = { (at: Int) in !liveOnly || at == 0 || now - at < Self.staleWindowMs }

        let sessions = model.sessions
            .filter { !$0.archived && $0.kind == .agent }
            .filter { !liveOnly || model.isLive($0.id) || fresh($0.updatedAt) }
            .map { meta in
                GraphSessionInput(meta: meta, activity: model.activity(meta.id),
                                  live: model.isLive(meta.id),
                                  branch: model.folderGitState(meta.cwd)?.branch)
            }

        let issues = projects.flatMap { project in
            (model.beads(project)?.issues ?? []).map { GraphIssueInput(project: project, issue: $0) }
        }

        // Trimmed: only the head of a dispatch prompt is ever read (its first line
        // for the card, a ticket-id scan for the edge), and these run to pages.
        let dispatches = registry
            .filter { fresh($0.at) }
            .map { record in
                var input = record.graphInput
                input.prompt = String(record.prompt.prefix(2000))
                return input
            }

        let worktrees = model.worktreeGroups.flatMap { [$0.main] + $0.children }

        var prs: [GraphPrInput] = model.trackedList.map { t in
            GraphPrInput(cwd: t.cwd, number: t.number, title: t.title, branch: t.branch,
                         checks: t.snapshot.checks, checkSummary: nil, tracked: true,
                         sessionId: t.sessionId, needsDecision: !t.notifications.isEmpty,
                         at: t.lastPolledAt ?? 0)
        }
        // Plus the plain open PRs on those projects, so a chain still reaches its PR
        // when the PR isn't under the tracking poller.
        let trackedKeys = Set(prs.map { "\($0.cwd)#\($0.number)" })
        for project in projects {
            for pr in model.prs(project)?.prs ?? [] where !trackedKeys.contains("\(project)#\(pr.number)") {
                prs.append(GraphPrInput(
                    cwd: project, number: pr.number, title: pr.title, branch: pr.branch,
                    checks: pr.checks,
                    checkSummary: pr.checkCount > 0 ? "\(pr.passedCount)/\(pr.checkCount) checks" : nil,
                    tracked: false, sessionId: nil, needsDecision: false, at: 0))
            }
        }

        return DispatchGraphInput(issues: issues, dispatches: dispatches, sessions: sessions,
                                  worktrees: worktrees, prs: prs)
    }

    /// Rebuild off the main actor — the ticket-id scan crosses every dispatch
    /// prompt, which is more work than a render should do.
    private func rebuild() async {
        let input = buildInput()
        let built = await Task.detached(priority: .userInitiated) {
            DispatchGraph.build(input)
        }.value
        graph = built
        if let selected, built.node(selected) == nil { self.selected = nil }
    }

    /// Load the caches the graph reads (they are lazy elsewhere in the app), and
    /// re-read the dispatch registry file. Runs on open and on the refresh button.
    private func prime() async {
        registry = await Task.detached(priority: .utility) {
            readOracleDispatchRegistry(limit: 80)
        }.value
        model.loadWorktrees()
        for project in projects {
            model.loadBeads(project)
            model.loadPrs(project)
        }
        // Branch names come from the per-folder git state; only the sessions that
        // are actually in play are worth a git call.
        for meta in model.sessions
            .filter({ $0.kind == .agent && !$0.archived })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(12) {
            model.loadFolderGitState(meta.cwd)
        }
        await rebuild()
    }
}

// MARK: - geometry

/// Where a `(layer, row)` grid slot lands, and the edge path between two nodes.
/// Plain arithmetic over a fixed grid — the "graph library" this panel deliberately
/// does not have.
enum GraphGeometry {
    static let nodeW: CGFloat = 190
    static let nodeH: CGFloat = 56
    static let colGap: CGFloat = 52
    static let rowGap: CGFloat = 16
    static let pad: CGFloat = 16

    static var colStride: CGFloat { nodeW + colGap }
    static var rowStride: CGFloat { nodeH + rowGap }

    static func x(_ layer: Int) -> CGFloat { pad + CGFloat(layer) * colStride + nodeW / 2 }
    static func y(_ row: Int) -> CGFloat { pad + CGFloat(row) * rowStride + nodeH / 2 }

    /// A flow edge leaves the source's right edge and enters the target's left
    /// edge as a flat cubic. A dependency edge joins two nodes in the same column,
    /// so it bows out to the left of both.
    static func path(from: GraphNode, to: GraphNode, kind: GraphEdgeKind) -> Path {
        var p = Path()
        let fromY = y(from.row), toY = y(to.row)
        if kind == .dependency || from.layer == to.layer {
            let left = x(from.layer) - nodeW / 2
            let bow = left - 22
            p.move(to: CGPoint(x: left, y: fromY))
            p.addCurve(to: CGPoint(x: x(to.layer) - nodeW / 2, y: toY),
                       control1: CGPoint(x: bow, y: fromY),
                       control2: CGPoint(x: bow, y: toY))
            return p
        }
        let start = CGPoint(x: x(from.layer) + nodeW / 2, y: fromY)
        let end = CGPoint(x: x(to.layer) - nodeW / 2, y: toY)
        let reach = (end.x - start.x) * 0.5
        p.move(to: start)
        p.addCurve(to: end,
                   control1: CGPoint(x: start.x + reach, y: start.y),
                   control2: CGPoint(x: end.x - reach, y: end.y))
        return p
    }
}

extension GraphNodeState {
    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .done: .green
        case .failed: .red
        case .blocked: .purple
        case .idle: .secondary
        }
    }
}

// MARK: - node card

/// One node: a state-tinted card with its kind glyph, primary label, detail line
/// and optional chip. Sized by the caller (`GraphGeometry`), so every column lines
/// up without measuring anything.
private struct GraphNodeCard: View {
    let node: GraphNode
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: node.kind.symbol)
                    .font(.system(size: 9)).foregroundStyle(node.state.color)
                Text(node.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if let badge = node.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(node.state.color.opacity(0.18))
                        .foregroundStyle(node.state.color)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            Text(node.detail.isEmpty ? " " : node.detail)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(node.state.color.opacity(selected ? 0.16 : 0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : node.state.color.opacity(0.35),
                              lineWidth: selected ? 1.6 : 1))
        .help(node.detail.isEmpty ? node.label : "\(node.label) — \(node.detail)")
        .clickCursor()
    }
}

/// The footer strip for the selected node: what it is, which project it belongs
/// to, and the one action that opens it where it lives.
private struct DispatchGraphDetail: View {
    let node: GraphNode
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbol).foregroundStyle(node.state.color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(node.label).font(.system(size: 12, weight: .medium))
                    Text(node.kind.columnTitle.lowercased())
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(node.state.rawValue)
                        .font(.system(size: 10)).foregroundStyle(node.state.color)
                }
                Text(node.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text((node.project as NSString).lastPathComponent)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if let title = actionTitle {
                Button(title, action: open).clickCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var actionTitle: String? {
        switch node.jump {
        case .session: "Open session"
        case .pr: "Open PR"
        case .ticket: "Open issues"
        case nil: nil
        }
    }
}

/// State → colour key, so the tints are readable without hovering every card.
private struct GraphLegend: View {
    private let items: [(GraphNodeState, String)] = [
        (.running, "running"), (.waiting, "needs you"), (.done, "done"), (.failed, "failed")
    ]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.0) { state, label in
                HStack(spacing: 3) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
