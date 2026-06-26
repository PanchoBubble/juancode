import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JuancodeCore
import JuancodeServices

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(OracleModel.self) private var oracle

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
        }
        .preferredColorScheme(.dark)
        .background(WindowBackground(color: .black))
        // Window-scoped key monitor for vim sidebar nav + ⌃H/⌃L pane focus (juancode-vgm).
        .background(PaneNavInstaller(model: model).frame(width: 0, height: 0))
        // Global command bar (juancode-6sw): Oracle, global Issues, Tracked PRs and
        // Worktrees live in the window toolbar — reachable from any session.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NotificationsBell()
                Button { model.showingTrackedPrs = true } label: {
                    Label("Tracked PRs", systemImage: "checklist")
                }
                .help("PRs under watch — CI-fix loops")
                .clickCursor()
                Button { model.showingTrackedIssues = true } label: {
                    Label("Tracked Issues", systemImage: "ticket")
                }
                .help("Linear issues under watch — do-or-escalate loops")
                .clickCursor()
                Button { model.showingWorktrees = true; model.loadWorktrees() } label: {
                    Label("Worktrees", systemImage: "externaldrive.badge.minus")
                }
                .help("Manage / clean git worktrees")
                .clickCursor()
                Button { model.showingSessionHealth = true } label: {
                    Label("Session Health", systemImage: model.unhealthySessions.isEmpty
                          ? "heart.text.square" : "heart.slash")
                }
                .help(model.unhealthySessions.isEmpty
                      ? "Session health — dead / stalled sessions"
                      : "\(model.unhealthySessions.count) session(s) need attention")
                .foregroundStyle(model.unhealthySessions.isEmpty ? Color.primary : Color.orange)
                .clickCursor()
                Button { model.showingRecurringTasks = true } label: {
                    Label("Recurring Tasks", systemImage: "repeat")
                }
                .help(model.recurringTasks.isEmpty
                      ? "Recurring tasks — scheduled re-runs of a prompt"
                      : "\(model.recurringTasks.count) recurring task(s) scheduled")
                .clickCursor()
                Button { oracle.open(tab: .issues) } label: {
                    Label("Issues", systemImage: "tray.full")
                }
                .help("Global issues (Oracle tracker)")
                .clickCursor()
                Button { oracle.open(tab: .chat) } label: {
                    Label("Oracle", systemImage: "sparkles")
                }
                .help("Oracle — global orchestration (⌃Space)")
                .clickCursor()
            }
        }
        // The Oracle helper opens as a centered overlay over the whole window,
        // from the toolbar or ⌃Space (juancode-wjg / juancode-6sw).
        .overlay { OracleDock() }
        // The file editor opens as a large, resizable floating window over the whole
        // window (not the narrow Changes side panel a sheet was confined near).
        .overlay { EditorHost() }
        .sheet(isPresented: $model.showingWorktrees) {
            WorktreesSheet()
        }
        .sheet(isPresented: $model.showingTrackedPrs) {
            TrackedPrsSheet()
        }
        .sheet(isPresented: $model.showingTrackedIssues) {
            TrackedIssuesSheet()
        }
        .sheet(isPresented: $model.showingSessionHealth) {
            SessionHealthSheet()
        }
        .sheet(isPresented: $model.showingRecurringTasks) {
            RecurringTasksSheet()
        }
        .sheet(isPresented: $model.showingNewSession) {
            NewSessionView()
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Sets the host `NSWindow`'s background to a solid color (and makes the title bar
/// transparent) so the whole window matches the black SwiftTerm views rather than
/// the default system-gray window background. Used as a hidden `.background(...)`.
private struct WindowBackground: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in apply(to: v?.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(to: nsView?.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = color
        window.titlebarAppearsTransparent = true
    }
}

/// Hidden bridge that installs the window-scoped keyboard monitor for vim-style
/// sidebar navigation and ⌃H/⌃L pane focus (juancode-vgm). The monitor must sit ahead
/// of the terminal in the responder chain, which only an NSEvent local monitor can do.
private struct PaneNavInstaller: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = installPaneNavigation(model: model, host: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var monitor: Any? }
}

/// The repo a working directory belongs to, for sidebar grouping. A juancode
/// worktree lives in a sibling `<repo>-worktrees/<name>` dir (see `createWorktree`);
/// map it back to `<repo>` so its sessions nest under the project instead of
/// floating as their own hash-named folder. Any other path is its own project.
func projectCwd(for cwd: String) -> String {
    let url = URL(fileURLWithPath: cwd)
    let parent = url.deletingLastPathComponent()
    let parentName = parent.lastPathComponent
    guard parentName.hasSuffix("-worktrees") else { return cwd }
    let repoBase = String(parentName.dropLast("-worktrees".count))
    guard !repoBase.isEmpty else { return cwd }
    return parent.deletingLastPathComponent().appendingPathComponent(repoBase).path
}

/// A folder's sessions, mirroring the web `FolderGroup` (groupByFolder).
private struct FolderGroup: Identifiable {
    let cwd: String
    /// Last path segment of the cwd, shown as the header label.
    let name: String
    let sessions: [SessionMeta]
    let running: Int
    var id: String { cwd }
}

/// Top-bar notification center: a bell with the unread count that opens a popover
/// listing every session with a pending turn-end notification. Clicking a row jumps
/// to that session (which clears its unread). Hidden-from-sidebar Oracle sessions are
/// excluded — the Oracle dock clears those itself.
private struct NotificationsBell: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var unread: [SessionMeta] { model.unreadSessionMetas }

    var body: some View {
        Button { showing = true } label: {
            Label("Notifications", systemImage: unread.isEmpty ? "bell" : "bell.badge.fill")
        }
        .help(unread.isEmpty
              ? "Notifications — sessions that finished or need a reply"
              : "\(unread.count) session(s) with unread activity")
        .foregroundStyle(unread.isEmpty ? Color.primary : Color.red)
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notifications")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                if unread.isEmpty {
                    Text("Nothing unread.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                } else {
                    ForEach(unread, id: \.id) { meta in
                        Button {
                            model.selection = meta.id
                            showing = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.activity(meta.id) == .waitingInput
                                      ? "questionmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(model.activity(meta.id) == .waitingInput ? .yellow : .green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(meta.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text((meta.cwd as NSString).lastPathComponent)
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .clickCursor()
                    }
                }
            }
            .frame(width: 280)
            .padding(.bottom, 4)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// Free-text filter over folder names/paths + session titles.
    @State private var query = ""
    /// When off (default) archived sessions are hidden from the list.
    @State private var showArchived = false
    /// Project folders the user has collapsed (by cwd); their session rows are hidden.
    @State private var collapsedFolders: Set<String> = []
    /// Folders expanded past the preview cap into a fixed-height, internally
    /// scrollable box (by cwd). Otherwise only the first `folderPreviewCount` show.
    @State private var expandedFolders: Set<String> = []
    /// The folder header currently under a drag (by cwd), for the drop highlight.
    @State private var dropTarget: String?

    /// How many session rows a folder shows before offering "Load more".
    private let folderPreviewCount = 5
    /// Max height of an expanded folder's scrollable session box (~5 rows).
    private let folderScrollMaxHeight: CGFloat = 220
    /// The session currently being renamed (drives the rename alert).
    @State private var renaming: SessionMeta?
    @State private var renameText = ""
    /// Whether the full-text transcript search sheet is open (juancode-wx9).
    @State private var showingSearch = false
    /// Whether the auth & MCP status sheet is open (juancode-daw).
    @State private var showingStatus = false
    /// Whether the session list holds keyboard focus, for vim-style nav (juancode-vgm).
    @FocusState private var listFocused: Bool

    /// How many archived sessions exist (for the toggle label / visibility).
    private var archivedCount: Int { model.sessions.filter(\.archived).count }

    /// Aggregate token/cost usage across visible non-archived sessions, for the
    /// sidebar footer total. Nil when nothing has usage yet.
    private var totalUsage: SessionUsage? {
        model.sessions.filter { !$0.archived }.aggregateUsage()
    }

    /// Sessions filtered by `query` (case-insensitive over title + cwd) and the
    /// archived toggle, then grouped by folder and sorted stably by cwd — mirrors
    /// the web sidebar.
    private var groups: [FolderGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Own sessions + discovered terminal sessions, grouped by project together.
        // Hide the pinned Oracle agent session — it's reachable from the Oracle dock,
        // not the per-project sidebar (juancode-wjg).
        let nonOracle = (model.sessions + model.externalSessions).filter { $0.cwd != OraclePaths.controlDir }
        // Only show folders that live under the workspace root (~/workdir); sessions
        // discovered elsewhere on disk are noise. Worktrees of in-workspace repos sit
        // in sibling `<repo>-worktrees/…` dirs, still under the root, so they survive.
        let inWorkspace = nonOracle.filter { Config.isUnderWorkspaceRoot($0.cwd) }
        let visible = showArchived ? inWorkspace : inWorkspace.filter { !$0.archived }
        let filtered = q.isEmpty
            ? visible
            : visible.filter {
                $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
            }
        // Group by the owning repo so linked worktrees nest under their project
        // instead of floating as their own folder. Prefer git's authoritative
        // worktree→repo map (`worktreeRepoRoots`); fall back to the path heuristic
        // (`<repo>-worktrees/…`) until that async scan lands.
        let byCwd = Dictionary(grouping: filtered, by: {
            model.worktreeRepoRoots[$0.cwd] ?? projectCwd(for: $0.cwd)
        })
        return byCwd.map { cwd, sessions in
            FolderGroup(
                cwd: cwd,
                name: (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent,
                sessions: sessions,
                running: sessions.filter { model.isLive($0.id) }.count)
        }
        .sorted { a, b in
            // Custom drag order first (folders the user has positioned); anything
            // not yet placed falls back to alphabetical, after the ordered ones.
            let ia = model.projectOrder.firstIndex(of: a.cwd)
            let ib = model.projectOrder.firstIndex(of: b.cwd)
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.cwd.localizedCompare(b.cwd) == .orderedAscending
            }
        }
    }

    /// Reorder projects by drag-and-drop: drop `dragged`'s header onto `target`'s to
    /// place it just before `target`. Persists the full current order so subsequent
    /// drags are stable.
    private func reorderProjects(moving dragged: String, onto target: String) {
        guard dragged != target else { return }
        var order = groups.map(\.cwd)
        guard let from = order.firstIndex(of: dragged) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: to)
        model.projectOrder = order
    }

    /// Selectable session IDs in on-screen order (folders flattened, collapsed folders
    /// and clipped previews respected, externals excluded) — what j/k steps through.
    /// Published into `model.navOrder` so the keyboard monitor can move the selection.
    private var visibleOrderedIDs: [String] {
        var ids: [String] = []
        for group in groups where !collapsedFolders.contains(group.cwd) {
            let s = group.sessions
            let shown = (s.count <= folderPreviewCount || expandedFolders.contains(group.cwd))
                ? s : Array(s.prefix(folderPreviewCount))
            for meta in shown where !model.isExternal(meta.id) { ids.append(meta.id) }
        }
        return ids
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            TextField("Filter sessions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(groups) { group in
                    Section {
                        if !collapsedFolders.contains(group.cwd) {
                            sessionList(group)
                        }
                    } header: {
                        FolderHeader(group: group, collapsed: collapsedFolders.contains(group.cwd)) {
                            if collapsedFolders.contains(group.cwd) {
                                collapsedFolders.remove(group.cwd)
                            } else {
                                collapsedFolders.insert(group.cwd)
                            }
                        }
                        // Drag a header onto another to reorder projects (persisted).
                        .overlay(alignment: .top) {
                            if dropTarget == group.cwd {
                                Rectangle().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .draggable(group.cwd) {
                            Text(group.name)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.black.opacity(0.8))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            dropTarget = nil
                            guard let dragged = items.first else { return false }
                            reorderProjects(moving: dragged, onto: group.cwd)
                            return true
                        } isTargeted: { hovering in
                            dropTarget = hovering ? group.cwd : (dropTarget == group.cwd ? nil : dropTarget)
                        }
                        // Let the project bar span the full sidebar width (no default
                        // section-header inset), so its fill/divider reach both edges.
                        .listRowInsets(EdgeInsets())
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No sessions yet." : "No matching sessions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if model.externalHasMore {
                    Button { model.loadMoreExternalSessions() } label: {
                        Label("Load more terminal sessions", systemImage: "ellipsis.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .clickCursor()
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            // ⌃H asks the list to take focus; j/k then move the selection (juancode-vgm).
            .onChange(of: model.sidebarFocusToken) { _, _ in listFocused = true }
            // Keep the keyboard monitor's nav order in sync with what's actually shown.
            .onChange(of: visibleOrderedIDs) { _, ids in model.navOrder = ids }
            // Keep the moved selection on-screen (g/G can jump far).
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
            }
            }
            if let total = totalUsage, let label = total.badgeLabel {
                Divider()
                HStack(spacing: 4) {
                    Text("Total").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help("Total token usage across visible sessions"
                    + (total.costUsd != nil ? " · estimated cost" : ""))
            }
            if archivedCount > 0 {
                Divider()
                Toggle(isOn: $showArchived) {
                    Text("Show archived (\(archivedCount))").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .background(Color.black)
        .onAppear { model.loadExternalSessions(); model.navOrder = visibleOrderedIDs }
        .toolbar {
            ToolbarItem {
                let anyExpanded = groups.contains { !collapsedFolders.contains($0.cwd) }
                Button {
                    collapsedFolders = anyExpanded ? Set(groups.map(\.cwd)) : []
                } label: {
                    Image(systemName: anyExpanded
                          ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(anyExpanded ? "Collapse all projects" : "Expand all projects")
                .clickCursor()
            }
            ToolbarItem {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("Search transcripts")
                    .clickCursor()
            }
            ToolbarItem {
                Button { showingStatus = true } label: { Image(systemName: "shield.lefthalf.filled") }
                    .help("Auth & MCP status")
                    .clickCursor()
            }
            ToolbarItem {
                Button { model.showingNewSession = true } label: { Image(systemName: "plus") }
                    .help("New session")
                    .clickCursor()
            }
        }
        .sheet(isPresented: $showingSearch) {
            SearchPanel()
        }
        .sheet(isPresented: $showingStatus) {
            StatusPanel()
        }
        .navigationTitle("juancode")
        .alert("Rename session", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let target = renaming { model.rename(target.id, to: renameText) }
                renaming = nil
            }
        }
        .perfTrackBody()
    }

    /// A folder's session rows: all of them if ≤ the preview cap; otherwise the
    /// first `folderPreviewCount` with a "Load more" affordance, and once expanded a
    /// fixed-height box that scrolls internally so the sidebar doesn't grow.
    @ViewBuilder
    private func sessionList(_ group: FolderGroup) -> some View {
        let sessions = group.sessions
        if sessions.count <= folderPreviewCount {
            ForEach(sessions, id: \.id) { meta in nativeRow(meta) }
        } else if expandedFolders.contains(group.cwd) {
            scrollBox(sessions, cwd: group.cwd)
        } else {
            ForEach(sessions.prefix(folderPreviewCount), id: \.id) { meta in nativeRow(meta) }
            Button { expandedFolders.insert(group.cwd) } label: {
                Label("Load more (\(sessions.count - folderPreviewCount))",
                      systemImage: "chevron.down.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .clickCursor()
        }
    }

    /// All of a folder's sessions inside a height-capped, internally scrolling box.
    /// These rows can't use the List's selection, so taps set the selection by hand.
    @ViewBuilder
    private func scrollBox(_ sessions: [SessionMeta], cwd: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions, id: \.id) { meta in scrollRow(meta) }
                }
            }
            .frame(maxHeight: folderScrollMaxHeight)
            Button { expandedFolders.remove(cwd) } label: {
                Label("Show less", systemImage: "chevron.up.circle").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .clickCursor()
            .padding(.top, 2)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    /// A row rendered as a native List cell (selection + keyboard nav via `.tag`).
    @ViewBuilder
    private func nativeRow(_ meta: SessionMeta) -> some View {
        let external = model.isExternal(meta.id)
        let row = sessionRow(meta)
            .tag(meta.id)
            .selectionDisabled(external)
            .contextMenu { rowContextMenu(meta) }
        // Pointing-hand on hover for the clickable (selectable) rows; external
        // rows aren't selectable, so they keep the default cursor.
        if external { row } else { row.pointerCursor() }
    }

    /// A row inside the scroll box: manual tap-to-select + highlight (the List's own
    /// selection machinery doesn't reach views nested in a ScrollView).
    @ViewBuilder
    private func scrollRow(_ meta: SessionMeta) -> some View {
        let external = model.isExternal(meta.id)
        let row = sessionRow(meta)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selection == meta.id ? Color.accentColor.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { if !external { model.selection = meta.id } }
            .contextMenu { rowContextMenu(meta) }
        // Pointing-hand on hover for the clickable rows; external rows can't be
        // selected by tap, so they keep the default cursor.
        if external { row } else { row.pointerCursor() }
    }

    private func sessionRow(_ meta: SessionMeta) -> SessionRow {
        let external = model.isExternal(meta.id)
        return SessionRow(meta: meta, activity: model.activity(meta.id),
                          live: model.isLive(meta.id), external: external,
                          tracked: external ? nil : model.trackedPr(forSession: meta.id),
                          trackedIssue: external ? nil : model.trackedIssue(forSession: meta.id),
                          unread: model.unreadSessions.contains(meta.id),
                          onResume: external ? { model.importExternalSession(meta.id) } : nil)
    }

    @ViewBuilder
    private func rowContextMenu(_ meta: SessionMeta) -> some View {
        if model.isExternal(meta.id) {
            Button("Resume in juancode") { model.importExternalSession(meta.id) }
        } else {
            Button("Rename…") { beginRename(meta) }
            if meta.archived {
                Button("Unarchive") { model.setArchived(meta.id, false) }
            } else {
                Button("Archive") { model.setArchived(meta.id, true) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(meta.id) }
        }
    }

    private func beginRename(_ meta: SessionMeta) {
        renameText = meta.title
        renaming = meta
    }
}

/// Collapsible section header for a folder: name (full path as tooltip), a
/// running-session badge, and a per-folder "+" agent menu that spawns a new
/// session in this folder. Mirrors the web sidebar's folder `<summary>`.
private struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    let group: FolderGroup
    let collapsed: Bool
    let toggle: () -> Void
    @State private var showingAgentPicker = false

    /// Sessions in this project with a pending turn-end notification.
    private var unreadCount: Int {
        group.sessions.filter { model.unreadSessions.contains($0.id) }.count
    }

    var body: some View {
        HStack(spacing: 6) {
            // Chevron + name + running-count + the empty stretch up to the "+" menu all
            // form the collapse toggle (the trailing Spacer lives *inside* the button so
            // the whole row width is clickable); the "+" menu and PR/issue badges stay
            // separately clickable.
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .help(group.cwd)
                    if group.running > 0 {
                        Text("\(group.running) running")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    // Unread roll-up: a red dot + count when any session in this project
                    // has a pending turn-end notification, so a collapsed folder still
                    // signals "something here wants you".
                    if unreadCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("\(unreadCount)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.red)
                        }
                        .help("\(unreadCount) session(s) here with unread activity")
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            // A popover (not a native Menu) so each agent option is a real SwiftUI
            // button: it gets the pointing-hand cursor + hover highlight, and clicks
            // register reliably (native menu rows did neither).
            Button { showingAgentPicker = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New session in \(group.cwd)")
            .clickCursor()
            .popover(isPresented: $showingAgentPicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        Button {
                            model.createInFolder(provider: p, cwd: group.cwd)
                            showingAgentPicker = false
                        } label: {
                            Text(Providers.spec(for: p).label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .clickCursor()
                    }
                }
                .padding(4)
            }
            FolderIssues(cwd: group.cwd)
            FolderPrs(cwd: group.cwd)
        }
        // Give each project a distinct, rounded bar: a subtle raised fill for contrast
        // against the session rows. Slight horizontal inset so the rounded corners read.
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06)))
        .padding(.horizontal, 6)
        .onAppear { model.loadPrs(group.cwd); model.loadBeads(group.cwd) }
    }
}

/// Build the single-line seed prompt auto-submitted to a PR-context session.
/// Mirrors the web `prPrompt`.
func prPrompt(_ pr: PullRequest) -> String {
    "Please help me work on pull request #\(pr.number) \"\(pr.title)\" (branch \(pr.branch)): \(pr.url) — start by reviewing the PR and its diff."
}

/// Per-folder open-PR badge + popover. Renders nothing unless the folder is a
/// GitHub repo with at least one open PR, so it stays invisible unless useful.
/// Mirrors the web `FolderPrs`: list with rolled-up CI status, free-text search,
/// "Mine" (author) and "Assigned to me" (assignee) filters, and per-PR
/// Open / Work on / Track actions.
private struct FolderPrs: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    @State private var showing = false
    @State private var query = ""
    @State private var mineOnly = false
    @State private var assignedOnly = false

    private var result: PrListResult? { model.prs(cwd) }
    private var all: [PullRequest] {
        guard let r = result, r.available else { return [] }
        return r.prs
    }
    private var viewer: String { result?.viewer ?? "" }
    private var mineCount: Int {
        viewer.isEmpty ? 0 : all.filter { $0.author == viewer }.count
    }
    private var assignedCount: Int {
        viewer.isEmpty ? 0 : all.filter { $0.assignees.contains(viewer) }.count
    }
    /// Offer the viewer-scoped filters only when we know who the viewer is.
    private var canFilterViewer: Bool { !viewer.isEmpty && all.count > 1 }

    private var list: [PullRequest] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { pr in
            if mineOnly && canFilterViewer && pr.author != viewer { return false }
            if assignedOnly && canFilterViewer && !pr.assignees.contains(viewer) { return false }
            if !q.isEmpty {
                let hay = "#\(pr.number) \(pr.title) \(pr.branch)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        if all.isEmpty {
            EmptyView()
        } else {
            Button {
                showing.toggle()
            } label: {
                Text("\(all.count) PR\(all.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("\(all.count) open pull request\(all.count == 1 ? "" : "s")")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                popover
            }
            .clickCursor()
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search + viewer filters.
            HStack(spacing: 6) {
                TextField("Filter PRs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if canFilterViewer {
                    Toggle("Mine (\(mineCount))", isOn: $mineOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                    Toggle("Assigned (\(assignedCount))", isOn: $assignedOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                }
            }
            .padding(8)
            Divider()
            if list.isEmpty {
                Text(query.isEmpty && !mineOnly && !assignedOnly ? "No open PRs" : "No matching PRs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list, id: \.number) { pr in
                            PrRow(pr: pr, cwd: cwd) { showing = false }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

/// One PR in the popover: CI-status dot, title, draft badge, and the
/// Open / Work on / Track actions.
private struct PrRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    /// Called to dismiss the popover after an action that navigates away.
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(checkColor).frame(width: 7, height: 7).help(checkLabel)
                Text("#\(pr.number)").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 12)).lineLimit(1).help(pr.title)
                if pr.draft {
                    Text("draft")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer(minLength: 4)
                Text(checkLabel).font(.system(size: 10)).foregroundStyle(checkColor)
            }
            HStack(spacing: 12) {
                Button("Open ↗") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .clickCursor()
                Button("Work on") {
                    dismiss()
                    model.workOnPr(pr, cwd: cwd)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .clickCursor()
                // Track (juancode-it5): hand the PR to a dedicated agent session that
                // watches for new review comments / CI status and auto-fixes the
                // obvious ones, escalating real decisions back here.
                if let t = tracked {
                    TrackBadge(state: t.state)
                    Button("Untrack") { model.untrackPr(t.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Stop watching this PR (keeps the session)")
                        .clickCursor()
                } else {
                    Button("Track") { model.trackPr(pr, cwd: cwd) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Watch this PR — auto-fix review comments & CI, escalate decisions")
                        .clickCursor()
                }
                Spacer()
            }
            .padding(.leading, 13)
            // Decisions the tracker won't make on its own — surfaced for the user.
            if let t = tracked, !t.notifications.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(t.notifications) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9)).foregroundStyle(.orange)
                            Text(note.message).font(.system(size: 10)).foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Button("Open") {
                                dismiss()
                                model.selection = t.sessionId
                            }
                            .buttonStyle(.borderless).font(.system(size: 9))
                            .clickCursor()
                            Button("Dismiss") {
                                model.resolveNotification(prId: t.id, notificationId: note.id)
                            }
                            .buttonStyle(.borderless).font(.system(size: 9))
                            .clickCursor()
                        }
                    }
                }
                .padding(.leading, 13)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }

    private var checkColor: Color {
        switch pr.checks {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        case .none: return .secondary
        }
    }

    private var checkLabel: String {
        switch pr.checks {
        case .passing: return "Checks passing"
        case .failing: return "Checks failing"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

/// A small pill showing what a tracked PR is currently doing.
struct TrackBadge: View {
    let state: TrackState
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(help)
    }
    private var label: String {
        switch state {
        case .watching: return "watching"
        case .fixing: return "fixing"
        case .needsDecision: return "needs you"
        }
    }
    private var color: Color {
        switch state {
        case .watching: return .secondary
        case .fixing: return .blue
        case .needsDecision: return .orange
        }
    }
    private var help: String {
        switch state {
        case .watching: return "Tracking — CI green, watching for new activity"
        case .fixing: return "Tracking — CI is running/failing; the agent is on it"
        case .needsDecision: return "Tracking — a change needs your decision"
        }
    }
}

/// Per-folder bd-issue badge + popover (juancode-sfh). Renders nothing unless the
/// folder has a beads tracker with at least one issue, so it stays invisible
/// otherwise. Mirrors `FolderPrs`: a count badge opening a searchable list with a
/// "Ready" filter and a per-issue "Work on" action that injects the issue's
/// context into the folder's focused session.
private struct FolderIssues: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    @State private var showing = false
    @State private var query = ""
    @State private var readyOnly = false

    private var result: BeadsResult? { model.beads(cwd) }
    private var all: [BeadsIssue] {
        guard let r = result, r.available else { return [] }
        // Open work only — closed issues aren't actionable to "work on".
        return r.issues.filter { $0.status != "closed" }
    }
    private var readyCount: Int { all.filter { $0.ready }.count }
    /// Offer the Ready filter only when it would change the list.
    private var canFilterReady: Bool { readyCount > 0 && readyCount < all.count }

    private var list: [BeadsIssue] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { issue in
            if readyOnly && canFilterReady && !issue.ready { return false }
            if !q.isEmpty {
                let hay = "\(issue.id) \(issue.title)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        if all.isEmpty {
            EmptyView()
        } else {
            Button {
                showing.toggle()
            } label: {
                Text("\(all.count) issue\(all.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("\(all.count) open bd issue\(all.count == 1 ? "" : "s")")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                popover
            }
            .clickCursor()
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter issues…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if canFilterReady {
                    Toggle("Ready (\(readyCount))", isOn: $readyOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                }
            }
            .padding(8)
            Divider()
            if list.isEmpty {
                Text(query.isEmpty && !readyOnly ? "No open issues" : "No matching issues")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list, id: \.id) { issue in
                            IssueRow(issue: issue, cwd: cwd) { showing = false }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

/// One bd issue in the popover: status dot, id, title, and a "Work on" action
/// that injects the issue's context into the folder's focused agent session.
private struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: BeadsIssue
    let cwd: String
    /// Called to dismiss the popover after an action that navigates away.
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(statusLabel)
                Text(issue.id).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(issue.title).font(.system(size: 12)).lineLimit(1).help(issue.title)
                if issue.blocked {
                    Text("blocked")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer(minLength: 4)
                Text("p\(issue.priority)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Work on") {
                    dismiss()
                    model.workOnIssue(issue, cwd: cwd)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Inject this issue's context into the focused session (starts one if none)")
                .clickCursor()
                Spacer()
            }
            .padding(.leading, 13)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if issue.blocked { return .orange }
        if issue.ready { return .green }
        return .secondary
    }
    private var statusLabel: String {
        if issue.blocked { return "Blocked" }
        if issue.ready { return "Ready" }
        return issue.status
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let activity: SessionActivity?
    let live: Bool
    /// A discovered terminal session not yet imported — shown with a marker and an
    /// explicit Resume button (so it isn't triggered by hover/selection).
    var external: Bool = false
    /// The PR this session is tracking, if any — drives the PR label (juancode-kxy).
    var tracked: TrackedPr? = nil
    /// The Linear issue this session is tracking, if any — drives the issue label (juancode-7sa).
    var trackedIssue: TrackedIssue? = nil
    /// Pending turn-end notification for this session — shows an unread dot until viewed.
    var unread: Bool = false
    /// Resume action for an external row; the row is otherwise non-interactive.
    var onResume: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title).lineLimit(1)
                    .font(.system(size: 13, weight: unread ? .semibold : .regular))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let t = tracked {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 8))
                    Text("#\(t.number)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(trackColor(t.state).opacity(0.2))
                .foregroundStyle(trackColor(t.state))
                .clipShape(Capsule())
                .help("Tracking PR #\(t.number) — \(t.state.rawValue)")
            }
            if let ti = trackedIssue {
                HStack(spacing: 3) {
                    Image(systemName: "ticket").font(.system(size: 8))
                    Text(ti.identifier).font(.system(size: 9, weight: .semibold).monospaced())
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(issueTrackColor(ti.state).opacity(0.2))
                .foregroundStyle(issueTrackColor(ti.state))
                .clipShape(Capsule())
                .help("Tracking \(ti.identifier) — \(ti.state.rawValue)")
            }
            if external {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("From your terminal")
                if let onResume {
                    Button(action: onResume) {
                        Image(systemName: "play.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Resume this conversation in juancode")
                    .clickCursor()
                }
            }
            if let label = meta.usage?.badgeLabel {
                Text(label)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Token usage" + (meta.usage?.costUsd != nil ? " · estimated cost" : ""))
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        (meta.cwd as NSString).lastPathComponent
    }

    private func trackColor(_ state: TrackState) -> Color {
        switch state {
        case .watching: return .secondary
        case .fixing: return .blue
        case .needsDecision: return .orange
        }
    }

    private func issueTrackColor(_ state: IssueTrackState) -> Color {
        switch state {
        case .watching: return .secondary
        case .active: return .blue
        case .needsDecision: return .orange
        case .done: return .green
        }
    }

    /// Status glyph in the leading slot. A session awaiting the user's answer to a
    /// question shows a distinctive question-mark icon instead of the plain dot, so
    /// "your turn to reply" stands out from the busy/idle dots. Both variants sit in
    /// a fixed-width slot so row titles stay aligned regardless of which is shown.
    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            if live, activity == .waitingInput {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .help("Waiting for your reply")
            } else {
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, alignment: .center)
        .overlay(alignment: .topTrailing) {
            if unread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1))
                    .offset(x: 1, y: -1)
                    .help("Unread — agent finished or needs your reply")
            }
        }
    }

    private var dotColor: Color { sessionDotColor(live: live, activity: activity) }
}

/// Status-dot color for a session: grey when not live, else activity-tinted (busy =
/// orange, waiting = blue, idle = green). Shared by the sidebar `SessionRow` and the
/// Oracle dock's session rail (juancode-cwa) so the two stay visually in sync.
func sessionDotColor(live: Bool, activity: SessionActivity?) -> Color {
    guard live else { return .secondary.opacity(0.4) }
    switch activity {
    case .busy: return .orange
    case .waitingInput: return .blue
    case .idle, .none: return .green
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selection, let meta = model.sessions.first(where: { $0.id == id }) {
            SessionContainer(meta: meta)
                .id(id) // fresh terminal per session
        } else {
            ContentUnavailableView(
                "No session selected",
                systemImage: "terminal",
                description: Text("Pick a session, or create one with +.")
            )
        }
    }
}

/// The two views the session's right-side panel can show: the working-tree
/// changes panel (diff + inline comments + git actions) or the folder's bd issues.
private enum SidePanelTab: String, CaseIterable { case changes = "Changes", issues = "Issues" }

struct SessionContainer: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta
    /// Active right-panel tab, remembered app-wide.
    @AppStorage("session.sidePanel.tab") private var tabRaw: String = SidePanelTab.changes.rawValue
    /// Whether the right-side panel is shown. Toggled from the header CTA.
    @AppStorage("session.sidePanel.shown") private var panelShown: Bool = true
    /// Persisted width of the right-side panel in the split.
    @AppStorage("session.sidePanel.width") private var panelWidth: Double = 420
    /// Persisted height of the bottom terminal panel in the split.
    @AppStorage("session.bottomPanel.height") private var bottomHeight: Double = 240

    private var tab: SidePanelTab {
        get { SidePanelTab(rawValue: tabRaw) ?? .changes }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                if let label = meta.usage?.badgeLabel {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Token usage" + (meta.usage?.costUsd != nil ? " · estimated cost" : ""))
                }
                Button {
                    model.toggleBottomTerminal()
                } label: {
                    Image(systemName: model.bottomTerminalShown ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle")
                }
                .help(model.bottomTerminalShown ? "Hide the terminal panel (⌃T)" : "Show the terminal panel (⌃T)")
                .clickCursor()
                Button {
                    panelShown.toggle()
                } label: {
                    Image(systemName: panelShown ? "sidebar.right" : "sidebar.squares.right")
                }
                .help(panelShown ? "Hide the Changes / Issues panel" : "Show the Changes / Issues panel")
                .clickCursor()
            }
            .padding(8)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    terminal
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.bottomTerminalShown {
                        DragResizeHandle(axis: .horizontal, value: $bottomHeight, min: 120, max: 720)
                        BottomTerminalPanel(cwd: meta.cwd)
                            .frame(height: CGFloat(bottomHeight))
                    }
                }
                // Breathing room so the terminal isn't glued to the divider/side panel.
                .padding(.leading, 10)
                .padding(.trailing, panelShown ? 10 : 0)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panelShown {
                    DragResizeHandle(axis: .vertical, value: $panelWidth, min: 280, max: .infinity)
                    sidePanel
                        .frame(width: CGFloat(panelWidth))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(meta.title)
        .perfTrackBody()
        // Opening an exited session auto-revives it — no manual "Reactivate" click.
        // The container is keyed by id in DetailView, so this fires once per open;
        // `reactivate` no-ops if already live and degrades to replay if it can't resume.
        .task(id: meta.id) {
            if !model.isLive(meta.id) { await model.reactivate(meta.id) }
        }
    }

    /// The right-side panel: a Changes | Issues tab switcher hosting the existing
    /// self-contained `ChangesPanel` (session diff) and `IssuesPanel` (folder bd
    /// issues). The active tab is remembered app-wide via @AppStorage.
    private var sidePanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { tab = $0 })) {
                ForEach(SidePanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .changes: ChangesPanel(sessionId: meta.id)
            case .issues: IssuesPanel(cwd: meta.cwd)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = model.liveSession(meta.id) {
            // Key by the Session's object identity: a permissions flip swaps in a
            // brand-new Session (same juancode id) behind the same pty, so this
            // forces a fresh terminal that subscribes to the new pty and replays
            // the carried-forward scrollback.
            // GhosttyKit surface by default; JUANCODE_SWIFTTERM=1 falls back to
            // SwiftTerm (see GhosttyLive.swift / bd spike).
            if TerminalBackendChoice.useGhostty {
                GhosttyLive(session: session,
                            focusToken: model.terminalFocusToken,
                            autoFocusOnAppear: !model.suppressTerminalAutoFocus)
                    .id(ObjectIdentifier(session))
            } else {
                SwiftTermLive(session: session,
                              focusToken: model.terminalFocusToken,
                              autoFocusOnAppear: !model.suppressTerminalAutoFocus)
                    .id(ObjectIdentifier(session))
            }
        } else {
            SwiftTermReplay(scrollback: model.scrollback(meta.id))
        }
    }
}

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ProviderId = .claude
    @State private var cwd: String = Config.defaultCwd
    // New sessions default to accept-all (skip permission prompts); toggle off per session.
    @State private var skipPermissions = true
    @State private var isolateWorktree = false
    @State private var creating = false
    @State private var showingDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2).bold()
            Form {
                Picker("Agent", selection: $provider) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        Text(Providers.spec(for: p).label).tag(p)
                    }
                }
                HStack {
                    TextField("Working directory", text: $cwd)
                    Button("Choose…") { showingDirPicker = true }
                        .clickCursor()
                }
                Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
                Toggle("Isolate in a fresh git worktree", isOn: $isolateWorktree)
            }
            continueExisting
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || cwd.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 480)
        // SwiftUI's native folder picker — unlike NSOpenPanel.runModal(), it does
        // not spin a nested modal run loop inside the sheet (which deadlocks).
        .fileImporter(isPresented: $showingDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let needsScope = url.startAccessingSecurityScopedResource()
                cwd = url.path
                if needsScope { url.stopAccessingSecurityScopedResource() }
            }
        }
        // Surface resumable CLI conversations for whichever folder is selected,
        // refreshed as the directory changes (juancode-g4c).
        .onAppear { model.loadResumableSessions(for: cwd) }
        .onChange(of: cwd) { _, new in model.loadResumableSessions(for: new) }
    }

    /// A `claude --resume`-style list of CLI conversations already started in the
    /// selected folder (in a terminal, or a prior juancode session). Selecting one
    /// adopts + resumes it in juancode rather than starting fresh. Hidden entirely
    /// when the folder has none. (juancode-g4c)
    @ViewBuilder
    private var continueExisting: some View {
        if model.resumableLoading || !model.resumableSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Continue existing").font(.system(size: 13, weight: .semibold))
                    if model.resumableLoading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if model.resumableSessions.isEmpty, model.resumableLoading {
                    Text("Looking for resumable conversations…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Resume a conversation already started in this folder.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.resumableSessions) { s in resumableRow(s) }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    @ViewBuilder
    private func resumableRow(_ s: ResumableSession) -> some View {
        Button { adoptResumable(s) } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).lineLimit(1).font(.system(size: 13))
                    Text("\(Providers.spec(for: s.provider).label) · started \(relativeTime(s.startMs))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private func adoptResumable(_ s: ResumableSession) {
        if model.adoptResumable(s, cwd: cwd) != nil { dismiss() }
    }

    private func start() {
        creating = true
        Task {
            let session = await model.create(provider: provider, cwd: cwd,
                                             skipPermissions: skipPermissions, isolateWorktree: isolateWorktree)
            creating = false
            if session != nil { dismiss() }
        }
    }
}
