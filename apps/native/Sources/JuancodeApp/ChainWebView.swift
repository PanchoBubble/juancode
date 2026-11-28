import SwiftUI
import JuancodeCore

// The chain as a web (juancode-cmew): every member a node, nested dispatches fanning
// outward from their dispatcher on rings, other recorded links drawn between. A
// session node's colour is its live state, and a dispatch edge takes its child's
// colour, so you can see at a glance which delegations are still talking.
// `ChainWeb.place` (JuancodeCore) decides positions; this file only draws.

struct ChainWebView: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    let query: String

    private static let ring: CGFloat = 130
    private static let dot: CGFloat = 30
    private static let labelWidth: CGFloat = 130
    private static let pad: CGFloat = 80

    var body: some View {
        let graph = ChainGraph.build(chain: chain,
                                     handoffs: model.chainHandoffs.handoffs(in: chain.slug),
                                     links: model.chainGraphLinks(chain))
        let nodes = graph.groups.flatMap(\.nodes) + graph.unconnected
        let raw = ChainWeb.place(nodes: nodes, edges: graph.edges, ring: Self.ring)
        let minX = raw.values.map(\.x).min() ?? 0, minY = raw.values.map(\.y).min() ?? 0
        let maxX = raw.values.map(\.x).max() ?? 0, maxY = raw.values.map(\.y).max() ?? 0
        let pos = raw.mapValues { CGPoint(x: $0.x - minX + Self.pad, y: $0.y - minY + Self.pad) }
        let size = CGSize(width: maxX - minX + 2 * Self.pad, height: maxY - minY + 2 * Self.pad)
        let rows = Dictionary(model.chainDetailRows(chain).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let names = ChainGraphNames(model: model, rows: rows)
        let states = Dictionary(uniqueKeysWithValues: nodes.map { ($0, WebState(of: $0, model: model)) })

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(WebState.legend, id: \.self) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.title)
                    }
                }
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for e in graph.edges {
                            guard let a = pos[e.from], let b = pos[e.to] else { continue }
                            var path = Path()
                            path.move(to: a); path.addLine(to: b)
                            let color = e.kind == .dispatched
                                ? (states[e.to]?.color ?? .secondary) : e.tint.opacity(0.6)
                            let active = e.kind == .dispatched && states[e.to]?.live == true
                            ctx.stroke(path, with: .color(color.opacity(active ? 0.9 : 0.45)),
                                       style: StrokeStyle(lineWidth: active ? 2.5 : 1.5,
                                                          dash: e.dashed ? [4, 3] : []))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    ForEach(nodes, id: \.self) { node in
                        if let p = pos[node], let state = states[node] {
                            WebNode(node: node, title: names.title(node), state: state,
                                    dimmed: !matches(node, rows))
                                .frame(width: Self.labelWidth)
                                .position(x: p.x, y: p.y + 10)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .padding(12)
            }
            .defaultScrollAnchor(.center)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.appPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.appDivider))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func matches(_ node: ChainGraphNodeID, _ rows: [ChainMemberRef: ChainDetailRow]) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        guard case let .member(ref) = node, let row = rows[ref] else { return false }
        return ChainDetail.matches(row, query: query)
    }
}

/// A node's state as the web colours it.
private enum WebState: Hashable {
    case working, needsInput, idle, sleeping, dead, other(kindIcon: String)

    static let legend: [WebState] = [.working, .needsInput, .idle, .sleeping, .dead]

    @MainActor
    init(of node: ChainGraphNodeID, model: AppModel) {
        let sessionId: String
        switch node {
        case .human: self = .other(kindIcon: "person.fill"); return
        case .chain: self = .other(kindIcon: "point.3.connected.trianglepath.dotted"); return
        case let .outsideSession(id): sessionId = id
        case let .member(ref):
            switch ref.kind {
            case .session: sessionId = ref.ref
            case .trackedPr: self = .other(kindIcon: "arrow.triangle.pull"); return
            case .beads, .linear: self = .other(kindIcon: "ticket"); return
            }
        }
        guard let meta = model.sessions.first(where: { $0.id == sessionId }) else { self = .dead; return }
        guard model.isLive(sessionId) else { self = meta.dormant ? .sleeping : .dead; return }
        switch model.activities[sessionId] {
        case .busy: self = .working
        case .waitingInput: self = .needsInput
        case .idle, nil: self = .idle
        }
    }

    var live: Bool { self == .working || self == .needsInput || self == .idle }

    var color: Color {
        switch self {
        case .working: .green
        case .needsInput: .orange
        case .idle: .blue
        case .sleeping: .gray
        case .dead: .red
        case .other: .teal
        }
    }

    var title: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs input"
        case .idle: "Idle"
        case .sleeping: "Sleeping"
        case .dead: "Exited / gone"
        case .other: ""
        }
    }

    var icon: String {
        if case let .other(icon) = self { return icon }
        return "terminal"
    }
}

private struct WebNode: View {
    @Environment(AppModel.self) private var model
    let node: ChainGraphNodeID
    let title: String
    let state: WebState
    let dimmed: Bool
    @State private var pulse = false

    var body: some View {
        Button { ChainGraphNodeCard.open(node, model: model) } label: {
            VStack(spacing: 4) {
                ZStack {
                    if state == .working {
                        // The only motion on the web: who is working right now.
                        Circle().stroke(state.color.opacity(0.5), lineWidth: 2)
                            .frame(width: 30, height: 30)
                            .scaleEffect(pulse ? 1.5 : 1).opacity(pulse ? 0 : 1)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                            .onAppear { pulse = true }
                    }
                    Circle().fill(state.color.opacity(state == .sleeping || state == .dead ? 0.35 : 0.9))
                        .frame(width: 30, height: 30)
                    Image(systemName: state.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(state.live ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.3 : 1)
        .help(state.title.isEmpty ? title : "\(title) — \(state.title)")
        .accessibilityLabel(state.title.isEmpty ? title : "\(title), \(state.title)")
        .clickCursor()
    }
}
