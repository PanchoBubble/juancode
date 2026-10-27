import SwiftUI
import AppKit
import JuancodeCore
import JuancodeDesktop

// The chain graph (juancode-043.8): a chain's members as connected cards. Sessions and
// Oracles show their agent, task and live activity; PRs and tickets show their state.
// A connection is drawn only where something recorded one — a daemon handoff, the
// Beads issue a handoff names, a tracked PR's or ticket's session — and is labelled and
// inspectable. Members nothing links sit in their own "no recorded relationship"
// group: sharing a chain says they belong together, never that one depends on or owns
// another. `ChainGraph` in JuancodeCore decides the nodes, edges, groups and places;
// this file draws them and routes clicks to the chain view's member tabs.

/// The overview's graph mode. `query` dims the members a search does not match.
struct ChainGraphView: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    let query: String

    @AppStorage("chainGraph.zoom") private var zoom: Double = 1
    @State private var selectedEdge: String?
    @State private var focusedNode: ChainGraphNodeID?
    @FocusState private var canvasFocused: Bool

    static let metrics = ChainGraphMetrics()
    private static let inspectorWidth: CGFloat = 300
    private static let wideEnough: CGFloat = 820
    private static let zoomRange: ClosedRange<Double> = 0.5...1.5

    var body: some View {
        let graph = ChainGraph.build(chain: chain,
                                     handoffs: model.chainHandoffs.handoffs(in: chain.slug),
                                     links: model.chainGraphLinks(chain))
        let rows = Dictionary(model.chainDetailRows(chain).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        let names = ChainGraphNames(model: model, rows: rows)
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideEnough
            let canvasWidth = wide ? geo.size.width - Self.inspectorWidth - 1 : geo.size.width
            let placement = ChainGraphPlacement.place(graph, metrics: Self.metrics,
                                                      width: max(canvasWidth / zoom - 24, Self.metrics.card.width))
            let layout = wide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    toolbar(graph, legend: canvasWidth >= 760,
                            fit: (canvasWidth - 24) / max(placement.size.width, 1))
                    Divider()
                    canvas(graph, placement: placement, rows: rows, names: names)
                }
                Divider()
                ChainRelationshipInspector(graph: graph, names: names, selected: $selectedEdge,
                                           supportsHandoffs: model.supportsChainHandoffs)
                    .frame(width: wide ? Self.inspectorWidth : nil)
                    .frame(maxHeight: wide ? .infinity : min(geo.size.height * 0.4, 260))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.appPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.appDivider))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: chain.slug) { _, _ in
            selectedEdge = nil
            focusedNode = nil
        }
    }

    // MARK: - Chrome

    private func toolbar(_ graph: ChainGraph, legend: Bool, fit: Double) -> some View {
        HStack(spacing: 10) {
            Text(summary(graph))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if legend { ChainGraphLegend() }
            HStack(spacing: 2) {
                Button { setZoom(zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (−)")
                    .accessibilityLabel("Zoom out")
                    .disabled(zoom <= Self.zoomRange.lowerBound)
                Button { setZoom(1) } label: {
                    Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(minWidth: 34)
                }
                .help("Reset zoom (0)")
                .accessibilityLabel("Reset zoom, now \(Int((zoom * 100).rounded())) percent")
                Button { setZoom(zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (+)")
                    .accessibilityLabel("Zoom in")
                    .disabled(zoom >= Self.zoomRange.upperBound)
                Button { setZoom(min(fit, 1)) } label: {
                    Image(systemName: "arrow.left.and.right.square")
                }
                .help("Fit the graph to the window's width")
                .accessibilityLabel("Fit to width")
            }
            .buttonStyle(.borderless)
            .clickCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func summary(_ graph: ChainGraph) -> String {
        let edges = graph.edges
        let handoffs = edges.filter { if case .handoff = $0.kind { return true } else { return false } }.count
        let open = edges.filter(\.isOpen).count
        var parts: [String] = []
        if model.supportsChainHandoffs {
            parts.append(handoffs == 0 ? "No handoffs recorded"
                         : "\(handoffs) handoff\(handoffs == 1 ? "" : "s")\(open > 0 ? " · \(open) open" : "")")
        } else {
            parts.append("Handoffs unavailable on this daemon")
        }
        let links = edges.count - handoffs - edges.filter { if case .handoffIssue = $0.kind { return true } else { return false } }.count
        if links > 0 { parts.append("\(links) tracking link\(links == 1 ? "" : "s")") }
        if !graph.unconnected.isEmpty { parts.append("\(graph.unconnected.count) unconnected") }
        return parts.joined(separator: " · ")
    }

    private func setZoom(_ value: Double) {
        let clamped = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        withAnimation(.easeOut(duration: 0.12)) { zoom = (clamped * 10).rounded() / 10 }
    }

    // MARK: - Canvas

    private func canvas(_ graph: ChainGraph, placement: ChainGraphPlacement,
                        rows: [ChainMemberRef: ChainDetailRow], names: ChainGraphNames) -> some View {
        let order = graph.groups.flatMap(\.nodes) + graph.unconnected
        let scale = CGFloat(zoom)
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(placement.boxes.enumerated()), id: \.offset) { _, box in
                        ChainGraphGroupBox(box: box, graph: graph)
                    }
                    ChainGraphEdges(graph: graph, placement: placement, selected: selectedEdge)
                    ForEach(order, id: \.self) { node in
                        if let frame = placement.nodes[node] {
                            ChainGraphNodeCard(node: node, row: rowFor(node, rows), names: names,
                                               relationships: graph.edges.filter { $0.from == node || $0.to == node }.count,
                                               dimmed: !matches(node, rows),
                                               focused: canvasFocused && focusedNode == node)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .id(node)
                        }
                    }
                    ChainGraphEdgeLabels(graph: graph, placement: placement, names: names,
                                         selected: $selectedEdge)
                }
                .frame(width: placement.size.width, height: placement.size.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: placement.size.width * scale, height: placement.size.height * scale,
                       alignment: .topLeading)
                .padding(12)
            }
            // A canvas smaller than the viewport sits at the top-left, not centred.
            .defaultScrollAnchor(.topLeading)
            .background(ChainGraphGrid())
            .focusable()
            .focused($canvasFocused)
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) { move(1, in: order, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, in: order, proxy: proxy) }
            .onKeyPress(.leftArrow) { move(-1, in: order, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: order, proxy: proxy) }
            .onKeyPress(.return) { open(focusedNode) }
            .onKeyPress(.space) { open(focusedNode) }
            .onKeyPress(characters: CharacterSet(charactersIn: "+=-0")) { press in
                switch press.characters {
                case "+", "=": setZoom(zoom + 0.1)
                case "-": setZoom(zoom - 0.1)
                default: setZoom(1)
                }
                return .handled
            }
            .gesture(MagnifyGesture().onEnded { value in setZoom(zoom * value.magnification) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chain graph for \(chain.name)")
            .accessibilityHint("Arrow keys move between cards, Return opens the focused card")
        }
    }

    private func rowFor(_ node: ChainGraphNodeID, _ rows: [ChainMemberRef: ChainDetailRow]) -> ChainDetailRow? {
        if case let .member(ref) = node { return rows[ref] }
        return nil
    }

    private func matches(_ node: ChainGraphNodeID, _ rows: [ChainMemberRef: ChainDetailRow]) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        guard let row = rowFor(node, rows) else { return false }
        return ChainDetail.matches(row, query: query)
    }

    private func move(_ by: Int, in order: [ChainGraphNodeID], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let i = focusedNode.flatMap { order.firstIndex(of: $0) }
        let next = i.map { ($0 + by + order.count) % order.count } ?? (by >= 0 ? 0 : order.count - 1)
        focusedNode = order[next]
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(order[next], anchor: .center) }
        return .handled
    }

    private func open(_ node: ChainGraphNodeID?) -> KeyPress.Result {
        guard let node else { return .ignored }
        ChainGraphNodeCard.open(node, model: model)
        return .handled
    }
}

/// Display names for graph nodes, shared by cards, labels and the inspector.
struct ChainGraphNames {
    let model: AppModel
    let rows: [ChainMemberRef: ChainDetailRow]

    @MainActor
    func title(_ node: ChainGraphNodeID) -> String {
        switch node {
        case let .member(ref): return rows[ref]?.title ?? ref.ref
        case .human: return "You"
        case let .outsideSession(id):
            return model.sessions.first { $0.id == id }?.title ?? "Session \(id.prefix(8))"
        }
    }
}

// MARK: - Cards

struct ChainGraphNodeCard: View {
    @Environment(AppModel.self) private var model
    let node: ChainGraphNodeID
    let row: ChainDetailRow?
    let names: ChainGraphNames
    let relationships: Int
    let dimmed: Bool
    let focused: Bool
    @State private var hovering = false

    /// Open a node: a member's tab in the chain view, an outside session as itself
    /// (which leaves the chain, like any other navigation). "You" opens nothing.
    @MainActor
    static func open(_ node: ChainGraphNodeID, model: AppModel) {
        switch node {
        case let .member(ref): model.selectChainMember(ref)
        case .human: return
        case let .outsideSession(id):
            guard model.sessions.contains(where: { $0.id == id }) else { return }
            model.selection = id
        }
    }

    var body: some View {
        let face = ChainGraphCardFace(node: node, row: row, model: model, names: names)
        Button { Self.open(node, model: model) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(face.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: face.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(face.accent)
                        Text(face.kicker)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let status = face.status {
                            HStack(spacing: 4) {
                                if let dot = face.dot { Circle().fill(dot).frame(width: 6, height: 6) }
                                Text(status).lineLimit(1)
                            }
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.appHairline(0.1)))
                        }
                    }
                    Text(face.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text(face.footer).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let when = face.when { Text(when).lineLimit(1) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.appPanelElevated : Color.appSurface))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.appDivider,
                              style: StrokeStyle(lineWidth: focused ? 2 : 1, dash: face.missing ? [4, 3] : [])))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 6 : 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!face.opens)
        .opacity(dimmed ? 0.3 : (face.missing ? 0.7 : 1))
        .onHover { hovering = $0 && face.opens }
        .help(face.help)
        .clickCursor()
        .contextMenu {
            if face.opens { Button("Open", action: { Self.open(node, model: model) }) }
            if let url = face.url { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.accessibility + ", \(relationships == 0 ? "no recorded relationships" : "\(relationships) recorded relationship\(relationships == 1 ? "" : "s")")")
        .accessibilityHint(face.opens ? "Opens this member" : "")
        .accessibilityAddTraits(.isButton)
    }
}

/// What one card says, from the member's row and the app's live state.
private struct ChainGraphCardFace {
    var icon = "questionmark"
    var kicker = ""
    var title = ""
    var status: String?
    var dot: Color?
    var accent: Color = .secondary
    var footer = ""
    var when: String?
    var help = ""
    var url: URL?
    var missing = false
    var opens = true

    var accessibility: String {
        [kicker, title, status, footer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @MainActor
    init(node: ChainGraphNodeID, row: ChainDetailRow?, model: AppModel, names: ChainGraphNames) {
        switch node {
        case .human:
            icon = "person.fill"
            kicker = "Human"
            title = "You"
            footer = "Named on a handoff"
            accent = .purple
            help = "A handoff names you as an owner"
            opens = false
        case let .outsideSession(id):
            let meta = model.sessions.first { $0.id == id }
            icon = "terminal"
            kicker = "Session · not in this chain"
            title = names.title(node)
            missing = meta == nil
            status = meta == nil ? "Gone" : sessionStatus(meta!, model: model)
            dot = meta.map { sessionDotColor(live: model.isLive($0.id), activity: model.activities[$0.id]) }
            footer = meta.map { (model.repoRoot(forSession: $0) as NSString).lastPathComponent } ?? id
            when = meta.map { relativeTime($0.updatedAt) }
            accent = .secondary
            help = meta == nil ? "A handoff names this session, which no longer exists"
                : "Open this session (leaves the chain)"
            opens = meta != nil
        case let .member(ref):
            let label = ChainTabLabel(row?.member ?? ChainMember(kind: ref.kind, ref: ref.ref), model: model)
            icon = label.icon
            title = row?.title ?? ref.ref
            status = row?.status
            missing = label.missing
            when = row.flatMap { $0.lastActivity }.map(relativeTime)
            url = URL(string: row?.member.url ?? model.tracked[ref.ref]?.url ?? "").flatMap { $0.scheme == nil ? nil : $0 }
            help = label.help
            switch ref.kind {
            case .session:
                let meta = model.sessions.first { $0.id == ref.ref }
                let oracle = model.isOracleSession(ref.ref)
                kicker = (oracle ? "Oracle" : "Session") + (meta.map { " · \($0.provider.rawValue)" } ?? "")
                dot = meta.map { sessionDotColor(live: model.isLive($0.id), activity: model.activities[$0.id]) }
                accent = oracle ? .purple : (dot ?? .secondary)
                footer = oracle ? "Oracle dock" : (row?.project ?? "")
            case .trackedPr:
                let pr = ChainPrRef(ref.ref)
                kicker = "Pull request" + (pr.number.map { " #\($0)" } ?? "")
                accent = label.tint
                footer = pr.project
                if let checks = model.tracked[ref.ref]?.snapshot.checks {
                    dot = checks.color
                }
            case .beads:
                kicker = "Beads · \(ref.ref)"
                accent = .teal
                footer = row?.project ?? "Not in a loaded tracker"
            case .linear:
                kicker = "Linear · \(ref.ref)"
                accent = .indigo
                footer = row?.project ?? ""
            }
        }
    }

    @MainActor
    private func sessionStatus(_ meta: SessionMeta, model: AppModel) -> String {
        guard model.isLive(meta.id) else { return meta.dormant ? "Sleeping" : "Exited" }
        switch model.activities[meta.id] {
        case .busy: return "Working"
        case .waitingInput: return "Needs input"
        case .idle, nil: return "Idle"
        }
    }
}

// MARK: - Groups, edges and labels

private struct ChainGraphGroupBox: View {
    let box: ChainGraphPlacement.Box
    let graph: ChainGraph

    var body: some View {
        let connected = box.group != nil
        let count = box.group.map { graph.groups[$0].nodes.count } ?? graph.unconnected.count
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appHairline(connected ? 0.035 : 0.02))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.appHairline(connected ? 0.18 : 0.14),
                              style: StrokeStyle(lineWidth: 1, dash: connected ? [] : [5, 4]))
            HStack(spacing: 6) {
                Image(systemName: connected ? "point.3.connected.trianglepath.dotted" : "square.dashed")
                Text(connected ? "Connected by recorded relationships" : "No recorded relationship")
                    .fontWeight(.semibold)
                Text("\(count)").foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 12).padding(.top, 9)
        }
        .frame(width: box.frame.width, height: box.frame.height)
        .offset(x: box.frame.minX, y: box.frame.minY)
        .help(connected ? "These members are joined by handoffs or tracking links"
            : "In this chain, but nothing records a handoff or link between these and anything else")
        .accessibilityHidden(true)
    }
}

/// Where an edge runs, shared by the stroke and its label so they cannot drift apart.
struct ChainGraphRoute {
    var start: CGPoint
    var c1: CGPoint
    var c2: CGPoint
    var end: CGPoint

    /// `lane` separates parallel edges between the same two nodes.
    init(from a: CGRect, to b: CGRect, lane: Int) {
        let bend = CGFloat(lane) * 22
        if a == b {
            // A self-handoff: a loop over the card's top edge.
            start = CGPoint(x: a.midX - 36, y: a.minY)
            end = CGPoint(x: a.midX + 36, y: a.minY)
            c1 = CGPoint(x: a.midX - 54, y: a.minY - 46 - bend)
            c2 = CGPoint(x: a.midX + 54, y: a.minY - 46 - bend)
        } else if b.minX >= a.maxX {
            start = CGPoint(x: a.maxX, y: a.midY)
            end = CGPoint(x: b.minX, y: b.midY)
            let dx = max((end.x - start.x) / 2, 30)
            c1 = CGPoint(x: start.x + dx, y: start.y + bend)
            c2 = CGPoint(x: end.x - dx, y: end.y + bend)
        } else if a.minX >= b.maxX {
            // Back to an earlier column: leave left, arrive on the right.
            start = CGPoint(x: a.minX, y: a.midY)
            end = CGPoint(x: b.maxX, y: b.midY)
            let dx = max((start.x - end.x) / 2, 30)
            c1 = CGPoint(x: start.x - dx, y: start.y + 26 + bend)
            c2 = CGPoint(x: end.x + dx, y: end.y + 26 + bend)
        } else {
            // Same column: bow out to the right.
            start = CGPoint(x: a.maxX, y: a.midY)
            end = CGPoint(x: b.maxX, y: b.midY)
            let out = 46 + abs(bend)
            c1 = CGPoint(x: start.x + out, y: start.y)
            c2 = CGPoint(x: end.x + out, y: end.y)
        }
    }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    var mid: CGPoint { point(0.5) }

    /// An edge and where it runs.
    struct Routed: Identifiable {
        let edge: ChainGraphEdge
        let route: ChainGraphRoute
        var id: String { edge.id }
    }

    /// Each edge's route, with parallel edges between one pair given separate lanes.
    static func all(_ graph: ChainGraph, _ placement: ChainGraphPlacement) -> [Routed] {
        var seen: [String: Int] = [:]
        return graph.edges.compactMap { e in
            guard let a = placement.nodes[e.from], let b = placement.nodes[e.to] else { return nil }
            let pair = [e.from.key, e.to.key].sorted().joined(separator: "|")
            let n = seen[pair, default: 0]
            seen[pair] = n + 1
            // 0, 1, -1, 2, -2… so the first edge runs straight.
            let lane = n == 0 ? 0 : (n % 2 == 1 ? (n + 1) / 2 : -(n / 2))
            return Routed(edge: e, route: ChainGraphRoute(from: a, to: b, lane: lane))
        }
    }
}

extension ChainGraphEdge {
    var tint: Color {
        switch kind {
        case let .handoff(h): return h.isOpen ? .orange : .secondary
        case .handoffIssue: return .teal
        case .watchesPr, .tracksTicket: return .blue
        }
    }

    var dashed: Bool {
        switch kind {
        case .handoff: return false
        case .handoffIssue, .watchesPr, .tracksTicket: return true
        }
    }

    var icon: String {
        switch kind {
        case let .handoff(h): return h.isOpen ? "arrow.right.circle.fill" : "checkmark.circle"
        case .handoffIssue: return "circle.hexagongrid"
        case .watchesPr: return "eye"
        case .tracksTicket: return "ticket"
        }
    }
}

private struct ChainGraphEdges: View {
    let graph: ChainGraph
    let placement: ChainGraphPlacement
    let selected: String?

    var body: some View {
        let routes = ChainGraphRoute.all(graph, placement)
        Canvas { ctx, _ in
            for routed in routes {
                let edge = routed.edge, route = routed.route
                var path = Path()
                path.move(to: route.start)
                path.addCurve(to: route.end, control1: route.c1, control2: route.c2)
                let on = edge.id == selected
                let width: CGFloat = on ? 3 : (edge.isOpen ? 2 : 1.4)
                let color = on ? Color.accentColor : edge.tint.opacity(edge.isOpen ? 0.95 : 0.7)
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round,
                                              dash: edge.dashed ? [5, 4] : []))
                // Arrowhead along the curve's final tangent.
                let tip = route.end
                let back = route.point(0.94)
                let angle = atan2(tip.y - back.y, tip.x - back.x)
                let size: CGFloat = on ? 9 : 7
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7)))
                head.addLine(to: CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7)))
                head.closeSubpath()
                ctx.fill(head, with: .color(color))
            }
        }
        .frame(width: placement.size.width, height: placement.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One clickable label per edge, at the curve's midpoint. Selecting one shows its
/// record in the inspector.
private struct ChainGraphEdgeLabels: View {
    let graph: ChainGraph
    let placement: ChainGraphPlacement
    let names: ChainGraphNames
    @Binding var selected: String?

    var body: some View {
        ForEach(ChainGraphRoute.all(graph, placement)) { routed in
            let edge = routed.edge, route = routed.route
            let on = edge.id == selected
            Button {
                selected = on ? nil : edge.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: edge.icon).font(.system(size: 9, weight: .semibold))
                    Text(edge.label).lineLimit(1).truncationMode(.tail)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(maxWidth: 150)
                .background(Capsule().fill(on ? Color.accentColor : Color.appPanelElevated))
                .overlay(Capsule().strokeBorder(on ? Color.clear : edge.tint.opacity(0.6)))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .position(route.mid)
            .help("\(edge.kind.title): \(names.title(edge.from)) → \(names.title(edge.to))\n\(edge.label)")
            .clickCursor()
            .accessibilityLabel("\(edge.kind.title) from \(names.title(edge.from)) to \(names.title(edge.to)): \(edge.label)")
            .accessibilityHint("Shows this relationship's details")
        }
        .frame(width: placement.size.width, height: placement.size.height, alignment: .topLeading)
    }
}

private struct ChainGraphGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var dots = Path()
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(Color.appHairline(0.12)))
        }
        .background(Color.appSurface)
        .accessibilityHidden(true)
    }
}

private struct ChainGraphLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(.orange, dashed: false, "Open handoff")
            item(.secondary, dashed: false, "Closed")
            item(.blue, dashed: true, "Tracking")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ color: Color, dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 16, y: 4)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 8)
            Text(text).lineLimit(1)
        }
    }
}

// MARK: - Inspector

/// Every recorded relationship as a list — the graph's keyboard and VoiceOver
/// alternative — and the full record of the one selected.
private struct ChainRelationshipInspector: View {
    @Environment(AppModel.self) private var model
    let graph: ChainGraph
    let names: ChainGraphNames
    @Binding var selected: String?
    let supportsHandoffs: Bool

    var body: some View {
        let edges = graph.edges
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected == nil ? "Relationships" : "Relationship")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if selected != nil {
                    Button("All") { selected = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .clickCursor()
                        .accessibilityLabel("Back to all relationships")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let edge = edges.first(where: { $0.id == selected }) {
                        ChainRelationshipDetail(edge: edge, graph: graph, names: names, selected: $selected)
                    } else if edges.isEmpty {
                        emptyState
                    } else {
                        ForEach(edges) { edge in
                            Button { selected = edge.id } label: { relationshipRow(edge) }
                                .buttonStyle(.plain)
                                .clickCursor()
                                .accessibilityLabel("\(edge.kind.title) from \(names.title(edge.from)) to \(names.title(edge.to)): \(edge.label)\(edge.handoff.map { ", \($0.state.title)" } ?? "")")
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.appBand)
    }

    @ViewBuilder private var emptyState: some View {
        Label("No recorded relationships", systemImage: "point.3.connected.trianglepath.dotted")
            .font(.callout.weight(.medium))
        Text("These members are grouped only because they share this chain. Being in a chain does not mean one depends on, owns or follows another, so no connections are drawn.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if supportsHandoffs {
            Text("A handoff recorded on this chain, or a PR or ticket tracked by one of its sessions, appears here as a connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("This daemon does not record handoffs. Update juancoded to see handoff history; only tracked PR and ticket links can be shown.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relationshipRow(_ edge: ChainGraphEdge) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: edge.icon)
                .foregroundStyle(edge.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(edge.label).font(.callout).lineLimit(2)
                Text("\(names.title(edge.from)) → \(names.title(edge.to))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 4) {
                    Text(edge.kind.title)
                    if let h = edge.handoff, case .handoff = edge.kind {
                        Text("·")
                        Text(h.state.title)
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.appHairline(0.05)))
        .contentShape(Rectangle())
    }
}

private struct ChainRelationshipDetail: View {
    @Environment(AppModel.self) private var model
    let edge: ChainGraphEdge
    let graph: ChainGraph
    let names: ChainGraphNames
    @Binding var selected: String?

    var body: some View {
        Label(edge.kind.title, systemImage: edge.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(edge.tint)
        Text(edge.handoff?.summary.isEmpty == false ? edge.handoff!.summary : edge.label)
            .font(.callout.weight(.semibold))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        field("From") { nodeLink(edge.from) }
        field("To") { nodeLink(edge.to) }
        if let h = edge.handoff {
            field("State") { Text(h.state.title + (h.closureReason.map { " — \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")) }
            field("Delivery") { Text(h.delivery.title) }
            if let issue = h.beadsIssue {
                field("Issue") {
                    let ref = ChainMemberRef(kind: .beads, ref: issue)
                    if model.chains[h.chainSlug]?.contains(ref) == true {
                        Button(issue) { model.selectChainMember(ref) }.buttonStyle(.link).clickCursor()
                    } else {
                        Text(issue).textSelection(.enabled)
                    }
                }
            }
            if let evidence = h.evidenceRef, !evidence.isEmpty {
                field("Evidence") {
                    if let url = URL(string: evidence), url.scheme?.hasPrefix("http") == true {
                        Link(evidence, destination: url).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(evidence).textSelection(.enabled)
                    }
                }
            }
            if h.createdAt > 0 { field("Created") { Text(relativeTime(h.createdAt)) } }
            if h.updatedAt > 0 && h.updatedAt != h.createdAt { field("Updated") { Text(relativeTime(h.updatedAt)) } }
            if let p = h.predecessorId { field("After") { handoffLink(p) } }
            if let s = h.successorId { field("Handed to") { handoffLink(s) } }
            field("Record") { Text(h.id).font(.caption.monospaced()).textSelection(.enabled) }
        } else {
            Text(edge.kind == .watchesPr
                 ? "The tracked PR's watch names this session as the one working it."
                 : "The tracked ticket names this session as the one working it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content().font(.callout)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func nodeLink(_ node: ChainGraphNodeID) -> some View {
        let title = names.title(node)
        switch node {
        case .human:
            Text(title)
        case let .outsideSession(id):
            if model.sessions.contains(where: { $0.id == id }) {
                Button(title + " (outside chain)") { ChainGraphNodeCard.open(node, model: model) }
                    .buttonStyle(.link).clickCursor()
            } else {
                Text("\(title) — gone").foregroundStyle(.secondary)
            }
        case .member:
            Button(title) { ChainGraphNodeCard.open(node, model: model) }
                .buttonStyle(.link).clickCursor().lineLimit(2)
        }
    }

    @ViewBuilder private func handoffLink(_ id: String) -> some View {
        let edgeId = "handoff:\(id)"
        if let other = graph.edges.first(where: { $0.id == edgeId }) {
            Button(other.label) { selected = edgeId }.buttonStyle(.link).clickCursor().lineLimit(1)
        } else {
            Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}
