import JuancodeWire
import SwiftUI

/// Drawer (projects → sessions) on the left, the selected session in the middle.
/// The right panel (Oracle chat, PRs) is an inspector; the bell lists sessions waiting for input.
struct RootView: View {
    let core: RemoteCore
    @Binding var selected: String?
    let unpair: () -> Void
    @State private var panel = false
    @State private var newSession = false
    @State private var chat = OracleChat()

    var body: some View {
        NavigationSplitView {
            DrawerView(core: core, selected: $selected, unpair: unpair)
        } detail: {
            if let id = selected {
                SessionView(core: core, sessionId: id).id(id)
            } else {
                ContentUnavailableView("No session", systemImage: "terminal",
                                       description: Text(core.lastError ?? "Pick one from the drawer."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newSession = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New session")
            }
            ToolbarItem(placement: .topBarTrailing) { BellButton(core: core) { selected = $0 } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { panel.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .accessibilityLabel("Oracle and PRs")
            }
        }
        .inspector(isPresented: $panel) {
            RightPanel(core: core, chat: chat) { selected = $0; panel = false }
        }
        .sheet(isPresented: $newSession) { NewSessionSheet(core: core) { selected = $0 } }
        .task { core.start() }
    }
}

struct DrawerView: View {
    let core: RemoteCore
    @Binding var selected: String?
    let unpair: () -> Void

    var body: some View {
        List(selection: $selected) {
            ForEach(ProjectGroup.group(core.sessions)) { project in
                Section(project.name) {
                    ForEach(project.sessions, id: \.id) { s in
                        HStack {
                            StatusDot(state: s.status == .exited ? nil : core.activity[s.id])
                            VStack(alignment: .leading) {
                                Text(s.title.isEmpty ? s.provider.rawValue : s.title).lineLimit(1)
                                Text(s.provider.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(s.id)
                    }
                }
            }
        }
        .refreshable { await core.refreshSessions() }
        .navigationTitle("juancode")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Circle().fill(core.connected ? .green : .red).frame(width: 8, height: 8)
                    .accessibilityLabel(core.connected ? "Connected" : "Disconnected")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu { Button("Unpair", role: .destructive, action: unpair) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct StatusDot: View {
    /// nil = exited or not yet reported.
    let state: SessionActivity?

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .accessibilityLabel(state.map { "\($0.rawValue)" } ?? "unknown")
    }

    private var color: Color {
        switch state {
        case .busy: .blue
        case .waitingInput: .orange
        case .idle: .green
        case nil: .gray
        }
    }
}
