import JuancodeWire
import SwiftUI

/// Chains list; a chain opens as a top→bottom map with a list toggle. Tracked PRs live here too.
struct ChainsView: View {
    let core: RemoteCore
    let open: (String) -> Void
    @AppStorage("chainSort") private var byCreation = false

    /// Newest first, by creation or by the latest update of a member session (or creation, if none).
    private func sorted(_ roots: [Chain]) -> [Chain] {
        func key(_ c: Chain) -> Int {
            if byCreation { return c.createdAt }
            let ids = Set(c.members.filter { $0.kind == .session }.map(\.ref))
            return core.sessions.filter { ids.contains($0.id) }.map(\.updatedAt).max() ?? c.createdAt
        }
        return roots.sorted { key($0) > key($1) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    section("ACTIVE", core.chains.outline(sorted(core.chains.activeRoots)))
                    section("CLOSED", core.chains.outline(sorted(core.chains.chains.filter { !$0.isActive && !core.chains.isNested($0) })))
                    if core.chains.isEmpty {
                        ContentUnavailableView("No chains", systemImage: "link")
                    }
                }
                .padding()
                .animation(.spring(duration: 0.3), value: core.chains)
            }
            .background(Tok.bg)
            .navigationTitle("Chains")
            .navigationDestination(for: String.self) { ChainDetailView(core: core, slug: $0, open: open) }
            .toolbar {
                Menu {
                    Picker("Sort", selection: $byCreation) {
                        Label("Last activity", systemImage: "clock").tag(false)
                        Label("Created", systemImage: "calendar").tag(true)
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                NavigationLink {
                    PrListView(core: core, open: open).navigationTitle("Tracked PRs")
                } label: { Label("PRs", systemImage: "arrow.triangle.pull") }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(chain: Chain, depth: Int)]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.caption).foregroundStyle(Tok.secondary).padding(.top, 8)
            ForEach(rows, id: \.chain.slug) { row in
                NavigationLink(value: row.chain.slug) { ChainListRow(core: core, chain: row.chain) }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(row.depth) * 16)
            }
        }
    }
}

struct ChainListRow: View {
    let core: RemoteCore
    let chain: Chain

    var body: some View {
        let sessions = chain.members.filter { $0.kind == .session }.compactMap { m in core.sessions.first { $0.id == m.ref } }
        let waiting = sessions.filter(core.isWaiting).count
        HStack(spacing: 12) {
            Image(systemName: "link").foregroundStyle(Tok.chain)
                .frame(width: 32, height: 32).background(Tok.chainBg, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(chain.name).font(.body.weight(.medium)).foregroundStyle(Tok.text).lineLimit(1)
                Text("\(chain.members.count) items · \(sessions.filter { $0.status != .exited }.count) running")
                    .font(.caption).foregroundStyle(Tok.secondary)
            }
            Spacer()
            if waiting > 0 {
                Label("\(waiting)", systemImage: "hand.raised.fill").font(.caption.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Tok.waiting, in: Capsule())
            }
            Text(chain.isActive ? "Active" : "Closed").font(.caption)
                .foregroundStyle(chain.isActive ? .green : Tok.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tok.secondary)
        }
        .padding(12)
        .background(waiting > 0 ? Tok.waitingBg : Tok.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { if waiting > 0 { RoundedRectangle(cornerRadius: 12).stroke(Tok.waiting) } }
    }
}

struct ChainDetailView: View {
    let core: RemoteCore
    let slug: String
    let open: (String) -> Void
    @State private var asMap = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let chain = core.chains[slug] {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(chain.isActive ? "Active" : "Closed").font(.caption.weight(.semibold))
                        .foregroundStyle(chain.isActive ? .green : Tok.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Tok.surface, in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                }
                .padding(.horizontal)
                Picker("View", selection: $asMap.animation(.snappy)) {
                    Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if asMap {
                    canvas(chain).transition(.opacity)
                } else {
                    ScrollView { list(chain).padding() }.transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.3), value: chain)
            .background(Tok.bg)
            .navigationTitle(chain.name)
        } else {
            ContentUnavailableView("Chain removed", systemImage: "link")
        }
    }

    // MARK: Map: a pan/zoom canvas of who dispatched whom (`parentSessionId`), nested chains
    // under the session that dispatched them; members with no recorded link sit in a row below.

    private func canvas(_ chain: Chain) -> some View {
        let members = chain.members
        let nested = core.chains.children(of: chain.slug)
        let sessionKey = { (id: String) in "s:\(id)" }
        let keys = members.map { $0.kind == .session ? sessionKey($0.ref) : "m:\($0.kind.rawValue):\($0.ref)" }
            + nested.map { "c:\($0.slug)" }
        let keySet = Set(keys)
        var parent: [String: String] = [:]
        for m in members where m.kind == .session {
            if let p = core.sessions.first(where: { $0.id == m.ref })?.parentSessionId, keySet.contains(sessionKey(p)) {
                parent[sessionKey(m.ref)] = sessionKey(p)
            }
        }
        for c in nested {
            let ids = Set(c.members.filter { $0.kind == .session }.map(\.ref))
            if let p = core.sessions.first(where: { ids.contains($0.id) && $0.parentSessionId.map { keySet.contains(sessionKey($0)) } == true })?
                .parentSessionId {
                parent["c:\(c.slug)"] = sessionKey(p)
            }
        }
        let layout = ChainCanvasLayout(keys: keys, parent: parent)
        var cards: [String: AnyView] = [:]
        for (k, m) in zip(keys, members) { cards[k] = AnyView(memberCard(m)) }
        for c in nested { cards["c:\(c.slug)"] = AnyView(NavigationLink(value: c.slug) { nestedCard(c) }.buttonStyle(.plain)) }
        return ZoomCanvas(size: layout.size) {
            ZStack(alignment: .topLeading) {
                Path { path in
                    for (child, p) in parent {
                        guard let a = layout.pos[p], let b = layout.pos[child] else { continue }
                        let from = CGPoint(x: a.x, y: a.y + ChainCanvasLayout.card.height / 2)
                        let to = CGPoint(x: b.x, y: b.y - ChainCanvasLayout.card.height / 2)
                        let mid = (from.y + to.y) / 2
                        path.move(to: from)
                        path.addCurve(to: to, control1: CGPoint(x: from.x, y: mid), control2: CGPoint(x: to.x, y: mid))
                    }
                }
                .stroke(Tok.chain.opacity(0.7), lineWidth: 2)
                ForEach(keys, id: \.self) { k in
                    if let p = layout.pos[k] {
                        cards[k].frame(width: ChainCanvasLayout.card.width, height: ChainCanvasLayout.card.height)
                            .position(p)
                    }
                }
            }
        }
    }

    private func memberCard(_ m: ChainMember) -> some View {
        let session = m.kind == .session ? core.sessions.first { $0.id == m.ref } : nil
        let waiting = session.map(core.isWaiting) ?? false
        return Button { tapMember(m, session) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let session { ProviderBadge(provider: session.provider, size: 18) } else { Image(systemName: icon(m.kind)) }
                    Text((m.role ?? kindLabel(m.kind)).uppercased()).font(.caption2.weight(.semibold))
                        .foregroundStyle(m.role != nil ? Tok.chain : Tok.secondary)
                    if m.done == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(session?.displayTitle ?? m.title ?? m.ref).font(.subheadline.weight(.medium))
                    .foregroundStyle(Tok.text).lineLimit(2).multilineTextAlignment(.leading)
                if let session {
                    StatusLabel(state: core.liveActivity(session), exited: session.status == .exited)
                    ContextMeter(percent: session.usage?.contextPercent)
                } else if m.kind != .session {
                    Text(m.ref).font(.caption).foregroundStyle(Tok.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(waiting ? Tok.waitingBg : Tok.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(waiting ? Tok.waiting : Tok.surface2))
        }
        .buttonStyle(.plain)
    }

    private func nestedCard(_ c: Chain) -> some View {
        HStack {
            Image(systemName: "link").foregroundStyle(Tok.chain)
            VStack(alignment: .leading) {
                Text("NESTED CHAIN").font(.caption2.weight(.semibold)).foregroundStyle(Tok.chain)
                Text(c.name).font(.subheadline.weight(.medium)).foregroundStyle(Tok.text).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.chainBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.chain))
    }

    // MARK: List

    private func list(_ chain: Chain) -> some View {
        let sessions = chain.members.filter { $0.kind == .session }.compactMap { m in core.sessions.first { $0.id == m.ref } }
        return VStack(alignment: .leading, spacing: 8) {
            SessionRows(core: core, sessions: sessions, open: open)
            ForEach(chain.members.filter { $0.kind != .session }, id: \.self) { m in
                Button { tapMember(m, nil) } label: {
                    HStack {
                        Image(systemName: icon(m.kind)).foregroundStyle(Tok.secondary).frame(width: 32)
                        VStack(alignment: .leading) {
                            Text(m.title ?? m.ref).foregroundStyle(Tok.text).lineLimit(1)
                            Text("\(kindLabel(m.kind)) · \(m.ref)").font(.caption).foregroundStyle(Tok.secondary).lineLimit(1)
                        }
                        Spacer()
                        if m.done == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    .padding(12).background(Tok.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            ForEach(core.chains.children(of: chain.slug)) { c in
                NavigationLink(value: c.slug) { ChainListRow(core: core, chain: c) }.buttonStyle(.plain)
            }
        }
    }

    private func tapMember(_ m: ChainMember, _ session: SessionMeta?) {
        if let session { return open(session.id) }
        let url = m.url ?? (m.kind == .trackedPr ? core.trackedPrs.first { $0.id == m.ref }?.url : nil)
        if let url, let u = URL(string: url) { openURL(u) }
    }

    private func icon(_ k: ChainMemberKind) -> String {
        switch k {
        case .session: "terminal"
        case .trackedPr: "arrow.triangle.pull"
        case .beads: "circle.grid.2x2"
        case .linear: "checkmark.circle"
        }
    }

    private func kindLabel(_ k: ChainMemberKind) -> String {
        switch k {
        case .session: "session"
        case .trackedPr: "tracked PR"
        case .beads: "beads"
        case .linear: "linear"
        }
    }
}

/// Tree layout for the chain canvas: leaves take consecutive columns, a parent centres over its
/// children, each depth a row. Nodes with neither parent nor children wrap in rows below the trees.
struct ChainCanvasLayout {
    static let card = CGSize(width: 170, height: 118)
    private static let col: CGFloat = 190, row: CGFloat = 170, pad: CGFloat = 20

    var pos: [String: CGPoint] = [:]
    var size: CGSize = .zero

    init(keys: [String], parent: [String: String]) {
        var children: [String: [String]] = [:]
        for k in keys { if let p = parent[k] { children[p, default: []].append(k) } }
        var slot = 0, maxDepth = -1, placed = Set<String>()
        func place(_ k: String, _ depth: Int) -> CGFloat {
            placed.insert(k)
            maxDepth = max(maxDepth, depth)
            let kids = (children[k] ?? []).filter { !placed.contains($0) } // a cycle ends here
            let x: CGFloat
            if kids.isEmpty { x = CGFloat(slot); slot += 1 } else {
                let xs = kids.map { place($0, depth + 1) }
                x = (xs.first! + xs.last!) / 2
            }
            pos[k] = CGPoint(x: Self.pad + x * Self.col + Self.card.width / 2,
                             y: Self.pad + CGFloat(depth) * Self.row + Self.card.height / 2)
            return x
        }
        for k in keys where parent[k] == nil && children[k] != nil { _ = place(k, 0) }
        let loose = keys.filter { !placed.contains($0) }
        let cols = max(2, slot)
        for (i, k) in loose.enumerated() {
            let r = maxDepth + 1 + i / cols
            pos[k] = CGPoint(x: Self.pad + CGFloat(i % cols) * Self.col + Self.card.width / 2,
                             y: Self.pad + CGFloat(r) * Self.row + Self.card.height / 2)
        }
        let rows = maxDepth + 1 + (loose.count + cols - 1) / cols
        let width = CGFloat(max(slot, loose.isEmpty ? 1 : min(cols, loose.count)))
        size = CGSize(width: 2 * Self.pad + width * Self.col - (Self.col - Self.card.width),
                      height: 2 * Self.pad + CGFloat(rows) * Self.row - (Self.row - Self.card.height))
    }
}

/// Two-axis scroll with pinch zoom (0.3x–2x); opens fitted to the width, never below half size.
struct ZoomCanvas<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content
    @State private var zoom: CGFloat?
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let z = (zoom ?? max(0.5, min(1, geo.size.width / size.width))) * pinch
            ScrollView([.horizontal, .vertical]) {
                content
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .scaleEffect(z, anchor: .topLeading)
                    .frame(width: size.width * z, height: size.height * z, alignment: .topLeading)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, state, _ in state = v.magnification }
                    .onEnded { v in
                        let base = zoom ?? max(0.5, min(1, geo.size.width / size.width))
                        zoom = min(2, max(0.3, base * v.magnification))
                    })
        }
    }
}
