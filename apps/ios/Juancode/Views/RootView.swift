import JuancodeWire
import SwiftUI

/// The selected session full-screen, with the action dock floating bottom-right
/// (juancode-3aq8.10). + and Active open as popovers that spring from their button;
/// projects, search and chains slide up as sheets.
struct RootView: View {
    let core: RemoteCore
    @Binding var selected: String?
    let unpair: () -> Void
    @State private var panel: Panel?
    @State private var popover: Popover?
    @State private var oracle = false
    @State private var keyboardUp = false
    @AppStorage("dockHidden") private var dockCollapsed = true
    @State private var chat = OracleChat()

    enum Panel: String, Identifiable { case projects, search, chains; var id: String { rawValue } }
    enum Popover { case new, active }

    private var current: SessionMeta? { core.sessions.first { $0.id == selected } }

    var body: some View {
        NavigationStack {
            Group {
                if let id = selected {
                    SessionView(core: core, sessionId: id).id(id)
                } else {
                    ContentUnavailableView("No session", systemImage: "terminal",
                                           description: Text(core.lastError ?? "Tap ⌃ for actions, then ☰ or ⚡︎."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text(core.connected ? "Connected" : core.lastError ?? "Disconnected")
                        Button("Unpair", role: .destructive, action: unpair)
                    } label: {
                        Circle().fill(core.connected ? .green : .red).frame(width: 8, height: 8)
                    }
                    .accessibilityLabel(core.connected ? "Connected" : "Disconnected")
                }
            }
        }
        .overlay {
            if popover != nil {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { popover = nil } }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !keyboardUp {
                VStack(alignment: .trailing, spacing: 8) {
                    if !dockCollapsed {
                        HStack(alignment: .bottom, spacing: 10) {
                            if let popover { popoverCard(popover) }
                            ActionDock(core: core, popover: popover) { tap($0) }
                        }
                        .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    dockToggle
                }
                .padding(.trailing, 12)
                .padding(.bottom, 96) // clear the key row and input bar
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $panel) { p in
            Group {
                switch p {
                case .projects: ProjectsView(core: core, open: open)
                case .search: SearchView(core: core, open: open)
                case .chains: ChainsView(core: core, open: open)
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $oracle) {
            NavigationStack {
                OracleChatView(core: core, chat: chat)
                    .navigationTitle("Oracle").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { oracle = false } }
            }
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.snappy) { keyboardUp = true; popover = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { keyboardUp = false }
        }
        .task { core.start() }
    }

    /// Always on screen so the dock can come back; a dot stands in for the hidden waiting badge.
    private var dockToggle: some View {
        let waiting = dockCollapsed && core.sessions.contains(where: core.isWaiting)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { popover = nil; dockCollapsed.toggle() }
        } label: {
            Image(systemName: dockCollapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Tok.text)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Tok.surface2))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if waiting { Circle().fill(Tok.waiting).frame(width: 10, height: 10) }
                }
                .frame(width: 52) // centred under the + button
        }
        .accessibilityLabel(dockCollapsed ? "Show actions" : "Hide actions")
    }

    private func tap(_ item: ActionDock.Item) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            switch item {
            case .new: popover = popover == .new ? nil : .new
            case .active: popover = popover == .active ? nil : .active
            case .projects: popover = nil; panel = .projects
            case .search: popover = nil; panel = .search
            case .chains: popover = nil; panel = .chains
            }
        }
    }

    private func open(_ id: String) {
        withAnimation(.spring(duration: 0.3)) { popover = nil }
        panel = nil
        selected = id
    }

    @ViewBuilder private func popoverCard(_ p: Popover) -> some View {
        Group {
            switch p {
            case .new:
                NewSessionCard(core: core, cwd: current?.cwd ?? ProjectGroup.group(core.sessions).first?.path,
                               open: open, openOracle: { popover = nil; oracle = true })
            case .active:
                ActiveList(core: core, open: open)
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(Tok.bg2, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Tok.surface2))
        // Springs out of the dock: scale+opacity anchored at the dock's corner.
        .transition(.scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity))
    }
}

/// Vertical pill: chains, search, active (badge = waiting for input), projects, then +.
struct ActionDock: View {
    let core: RemoteCore
    let popover: RootView.Popover?
    let tap: (Item) -> Void

    enum Item { case chains, search, active, projects, new }

    var body: some View {
        let waiting = core.sessions.filter(core.isWaiting).count
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                button(.chains, "link", "Chains")
                button(.search, "magnifyingglass", "Search")
                button(.active, "bolt.fill", "Active sessions, \(waiting) waiting for input", selected: popover == .active)
                    .overlay(alignment: .topTrailing) {
                        if waiting > 0 {
                            Text("\(waiting)").font(.caption2.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 5).background(Tok.waiting, in: Capsule())
                                .offset(x: 4, y: -2)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring, value: waiting)
                button(.projects, "line.3.horizontal", "Projects")
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Tok.surface2))
            Button { tap(.new) } label: {
                Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .rotationEffect(.degrees(popover == .new ? 45 : 0))
                    .frame(width: 52, height: 52)
                    .background(popover == .new ? Tok.surface2 : Tok.blue, in: Circle())
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            }
            .accessibilityLabel(popover == .new ? "Close" : "New session")
        }
    }

    private func button(_ item: Item, _ icon: String, _ label: String, selected: Bool = false) -> some View {
        Button { tap(item) } label: {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(selected ? Tok.blue : Tok.text)
                .frame(width: 40, height: 40)
                .background(selected ? Tok.surface2 : .clear, in: Circle())
        }
        .accessibilityLabel(label)
    }
}
