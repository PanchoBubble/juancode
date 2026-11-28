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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(chain.isActive ? "Active" : "Closed").font(.caption.weight(.semibold))
                            .foregroundStyle(chain.isActive ? .green : Tok.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Tok.surface, in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }
                    Picker("View", selection: $asMap.animation(.snappy)) {
                        Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
                        Label("List", systemImage: "list.bullet").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if asMap { map(chain).transition(.opacity) } else { list(chain).transition(.opacity) }
                }
                .padding()
                .animation(.spring(duration: 0.3), value: chain)
            }
            .background(Tok.bg)
            .navigationTitle(chain.name)
        } else {
            ContentUnavailableView("Chain removed", systemImage: "link")
        }
    }

    // MARK: Map: orchestrator → roled sessions → tickets/PRs → nested chains, top to bottom.

    private func tiers(_ chain: Chain) -> [(label: String, cards: [AnyView])] {
        let sessions = chain.members.filter { $0.kind == .session }
        let orchestrators = sessions.filter { $0.role == "orchestrator" }
        let workers = sessions.filter { $0.role != "orchestrator" }
        let others = chain.members.filter { $0.kind != .session }
        let nested = core.chains.children(of: chain.slug)
        return [
            ("orchestrator", orchestrators.map { AnyView(memberCard($0)) }),
            ("sessions", workers.map { AnyView(memberCard($0)) }),
            ("items", others.map { AnyView(memberCard($0)) }),
            ("nested chains", nested.map { c in AnyView(NavigationLink(value: c.slug) { nestedCard(c) }.buttonStyle(.plain)) }),
        ].filter { !$0.cards.isEmpty }
    }

    private func map(_ chain: Chain) -> some View {
        let tiers = tiers(chain)
        return VStack(spacing: 0) {
            ForEach(Array(tiers.enumerated()), id: \.offset) { i, tier in
                if i > 0 { Rectangle().fill(Tok.surface2).frame(width: 2, height: 22) }
                Text(tier.label).font(.caption2).foregroundStyle(Tok.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Tok.surface, in: Capsule())
                Rectangle().fill(Tok.surface2).frame(width: 2, height: 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Array(tier.cards.enumerated()), id: \.offset) { $0.element }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
