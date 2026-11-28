import JuancodeWire
import SwiftUI

/// Rows of `SessionRow`s that open on tap, with list changes animated.
struct SessionRows: View {
    let core: RemoteCore
    let sessions: [SessionMeta]
    let open: (String) -> Void

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(sessions, id: \.id) { s in
                Button { open(s.id) } label: { SessionRow(core: core, session: s) }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.3), value: sessions.map(\.id))
    }
}

/// Active popover: running sessions, waiting-for-input first.
struct ActiveList: View {
    let core: RemoteCore
    let open: (String) -> Void

    private var running: [SessionMeta] {
        let live = core.sessions.filter { $0.kind == .agent && !$0.archived && $0.status != .exited }
            .sorted { $0.updatedAt > $1.updatedAt }
        return live.filter(core.isWaiting) + live.filter { !core.isWaiting($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active").font(.headline).foregroundStyle(Tok.text)
            if running.isEmpty {
                Text("Nothing running").foregroundStyle(Tok.secondary)
            } else {
                ScrollView { SessionRows(core: core, sessions: running, open: open) }
                    .frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ☰: every project that has sessions, search focused on open.
struct ProjectsView: View {
    let core: RemoteCore
    let open: (String) -> Void
    @State private var query = ""
    @State private var searching = true
    @AppStorage("showOldSessions") private var showOld = false

    private var projects: [ProjectGroup] {
        let all = ProjectGroup.group(core.sessions, recentOnly: !showOld)
        return query.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(projects) { p in
                NavigationLink(value: p.path) {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Tok.blue)
                        VStack(alignment: .leading) {
                            Text(p.name).foregroundStyle(Tok.text)
                            Text(p.path).font(.caption).foregroundStyle(Tok.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        let waiting = p.sessions.filter(core.isWaiting).count
                        if waiting > 0 {
                            Text("\(waiting)").font(.caption.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 6).background(Tok.waiting, in: Capsule())
                        }
                        Text("\(p.sessions.count)").foregroundStyle(Tok.secondary)
                    }
                }
                .listRowBackground(Tok.surface)
            }
            .scrollContentBackground(.hidden).background(Tok.bg)
            .animation(.default, value: projects.map(\.id))
            .searchable(text: $query, isPresented: $searching, prompt: "Search projects")
            .navigationTitle("Projects")
            .toolbar {
                Toggle(isOn: $showOld) { Label("Older than 2 weeks", systemImage: "clock.arrow.circlepath") }
                    .toggleStyle(.button)
            }
            .navigationDestination(for: String.self) { ProjectSessionsView(core: core, path: $0, open: open) }
            // Not .refreshable: pull-to-refresh fought the sheet's drag-to-dismiss.
            .task { await core.refreshSessions() }
        }
    }
}

/// One project's sessions; + starts a new one here.
struct ProjectSessionsView: View {
    let core: RemoteCore
    let path: String
    let open: (String) -> Void
    @State private var newSession = false
    @AppStorage("showOldSessions") private var showOld = false

    private var sessions: [SessionMeta] {
        ProjectGroup.group(core.sessions, recentOnly: !showOld).first { $0.path == path }?.sessions ?? []
    }

    var body: some View {
        ScrollView { SessionRows(core: core, sessions: sessions, open: open).padding() }
            .background(Tok.bg)
            .navigationTitle((path as NSString).lastPathComponent)
            .toolbar {
                Button { newSession = true } label: { Image(systemName: "plus") }.accessibilityLabel("New session here")
            }
            .sheet(isPresented: $newSession) {
                NewSessionCard(core: core, cwd: path, open: open, openOracle: {})
                    .padding().presentationDetents([.height(340)]).preferredColorScheme(.dark)
            }
    }
}

/// Client-side filter over session title/cwd/provider and chain names.
struct SearchView: View {
    let core: RemoteCore
    let open: (String) -> Void
    @State private var query = ""
    @State private var searching = true

    private var sessions: [SessionMeta] {
        let live = core.sessions.filter { $0.kind == .agent && !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
        guard !query.isEmpty else { return live }
        return live.filter {
            [$0.title, $0.cwd, $0.provider.rawValue].contains { $0.localizedCaseInsensitiveContains(query) }
                || core.chains.chain(forSession: $0.id)?.name.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var chains: [Chain] {
        query.isEmpty ? [] : core.chains.chains.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !chains.isEmpty {
                        Text("CHAINS").font(.caption).foregroundStyle(Tok.secondary)
                        ForEach(chains) { c in
                            NavigationLink(value: c.slug) { ChainListRow(core: core, chain: c) }.buttonStyle(.plain)
                        }
                        Text("SESSIONS").font(.caption).foregroundStyle(Tok.secondary).padding(.top, 8)
                    }
                    SessionRows(core: core, sessions: sessions, open: open)
                }
                .padding()
            }
            .background(Tok.bg)
            .searchable(text: $query, isPresented: $searching, prompt: "Sessions, projects, chains")
            .navigationTitle("Search")
            .navigationDestination(for: String.self) { ChainDetailView(core: core, slug: $0, open: open) }
        }
    }
}
