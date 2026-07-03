import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JuancodeCore
import JuancodeServices

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(OracleModel.self) private var oracle
    @Environment(Shortcuts.self) private var shortcuts
    /// Shown once at launch when the on-disk database failed to open and the app
    /// fell back to an in-memory store (juancode-4zk).
    @State private var showDbRecovery = false

    var body: some View {
        @Bindable var model = model
        // Screen-size-proportional default sidebar width (~20% of the window,
        // capped). `ideal` only applies until the user drags the split divider —
        // macOS autosaves manual column widths, so "manual wins" holds natively.
        let sidebarIdeal = PanelAutoSize.width(window: model.windowWidth,
                                               fraction: 0.20, min: 280, max: 380)
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarIdeal)
        } detail: {
            DetailView()
        }
        // Publish the window content width; drives all auto panel defaults.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .preferredColorScheme(model.themePreference.colorScheme)
        .background(WindowBackground(color: .appWindow))
        // Window-scoped key monitor for vim sidebar nav + ⌃H/⌃L pane focus (juancode-vgm).
        .background(PaneNavInstaller(model: model, oracle: oracle, shortcuts: shortcuts).frame(width: 0, height: 0))
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
                    Label("Worktrees", systemImage: model.workAtRiskList.isEmpty
                          ? "externaldrive.badge.minus" : "externaldrive.badge.exclamationmark")
                }
                .help(model.workAtRiskList.isEmpty
                      ? "Manage / clean git worktrees"
                      : "\(model.workAtRiskList.count) folder(s) with uncommitted or unpushed work")
                .foregroundStyle(model.workAtRiskList.isEmpty ? Color.primary : Color.orange)
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
                // Appearance toggle (juancode light/dark): click cycles
                // System → Light → Dark; the dropdown picks one directly.
                Menu {
                    Picker("Appearance", selection: $model.themePreference) {
                        ForEach(ThemePreference.allCases) { pref in
                            Label(pref.label, systemImage: pref.symbol).tag(pref)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label("Appearance", systemImage: model.themePreference.symbol)
                } primaryAction: {
                    model.themePreference = model.themePreference.next
                }
                .menuIndicator(.hidden)
                .help("Appearance: \(model.themePreference.label) — click to cycle, or pick")
                .clickCursor()
            }
        }
        // The file editor opens as a large, resizable floating window over the whole
        // window (not the narrow Changes side panel a sheet was confined near).
        .overlay { EditorHost() }
        // The Oracle helper opens as a docked overlay over the whole window, from the
        // toolbar or ⌃Space (juancode-wjg / juancode-6sw). Mounted LAST so it layers
        // above the editor: opening Oracle over an open editor draws on top of it, and
        // collapsing Oracle reveals the editor underneath. Both are `.overlay`s, so
        // neither reflows the split view beneath — no layout shift on open/close.
        .overlay { OracleDock() }
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
        .sheet(isPresented: $model.showingPromptPalette) {
            PromptPaletteView()
        }
        .sheet(isPresented: $model.showingSessionTemplates) {
            SessionTemplatesView()
        }
        .sheet(isPresented: $model.showingKillPort) {
            KillPortSheet()
        }
        // On-disk DB failed to open at launch → running in-memory; surface recovery.
        .sheet(isPresented: $showDbRecovery) {
            DatabaseRecoveryView()
        }
        .onAppear { if model.degradedReason != nil { showDbRecovery = true } }
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
    let oracle: OracleModel
    let shortcuts: Shortcuts

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = installPaneNavigation(
            model: model, oracle: oracle, shortcuts: shortcuts, host: v)
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
    private var atRiskNotices: [AppModel.WorkAtRiskNotice] { model.workAtRiskNotices }
    private var hasAny: Bool { !unread.isEmpty || !atRiskNotices.isEmpty }

    var body: some View {
        Button { showing = true } label: {
            Label("Notifications", systemImage: hasAny ? "bell.badge.fill" : "bell")
        }
        .help(hasAny
              ? "\(unread.count) unread · \(atRiskNotices.count) work-at-risk"
              : "Notifications — sessions that finished or need a reply")
        .foregroundStyle(!unread.isEmpty ? Color.red : (atRiskNotices.isEmpty ? Color.primary : Color.orange))
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
                // Work-at-risk: folders with uncommitted/unpushed work whose session
                // went idle or exited (juancode-rxu). Clicking opens the Worktrees
                // panel where the full list + actions live.
                if !atRiskNotices.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Work at risk")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.bottom, 4)
                    ForEach(atRiskNotices) { notice in
                        HStack(spacing: 8) {
                            Button {
                                model.showingWorktrees = true
                                model.loadWorktrees()
                                showing = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11)).foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(notice.title.isEmpty ? "A session" : notice.title)
                                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text((notice.path as NSString).lastPathComponent)
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .clickCursor()
                            Button {
                                model.dismissWorkAtRiskNotice(notice.id)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9))
                            }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                            .clickCursor()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                } else if unread.isEmpty {
                    // (the "Nothing unread" text above already covers the empty case)
                    EmptyView()
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
    /// Projects start collapsed (minimized by default) — see `seenFolders`.
    @State private var collapsedFolders: Set<String> = []
    /// Project cwds we've already applied the default-collapsed rule to. A folder is
    /// collapsed the first time it appears; afterwards the user's manual expand/collapse
    /// is left untouched even as the group list reshuffles.
    @State private var seenFolders: Set<String> = []
    /// Folders expanded past the preview cap into a fixed-height, internally
    /// scrollable box (by cwd). Otherwise only the first `folderPreviewCount` show.
    @State private var expandedFolders: Set<String> = []
    /// The folder header currently under a drag (by cwd), for the drop highlight.
    @State private var dropTarget: String?

    /// How many session rows a folder shows before offering "Load more".
    private let folderPreviewCount = 5
    /// Max height of an expanded folder's scrollable session box (~5 rows at the
    /// 220 default). User-resizable via the drag handle under the box; persisted.
    @AppStorage("session.folderScroll.maxHeight") private var folderScrollMaxHeight: Double = 220
    /// The session currently being renamed (drives the rename alert).
    @State private var renaming: SessionMeta?
    @State private var renameText = ""
    /// Whether the full-text transcript search sheet is open (juancode-wx9).
    @State private var showingSearch = false
    /// Whether the auth & MCP status sheet is open (juancode-daw).
    @State private var showingStatus = false
    /// Whether the session list holds keyboard focus, for vim-style nav (juancode-vgm).
    @FocusState private var listFocused: Bool
    /// Whether the "Filter sessions…" field holds focus, so ⌃F can jump to it.
    @FocusState private var searchFocused: Bool

    /// How many archived sessions exist (for the toggle label / visibility).
    private var archivedCount: Int { model.sessions.filter(\.archived).count }

    /// Aggregate token/cost usage across visible non-archived sessions, for the
    /// sidebar footer total. Nil when nothing has usage yet.
    private var totalUsage: SessionUsage? {
        model.sessions.filter { !$0.archived }.aggregateUsage()
    }

    /// Colour for a budget level, or nil (secondary) when off/ok (juancode-qoc).
    private func budgetTint(_ level: BudgetLevel) -> Color? {
        switch level {
        case .off, .ok: return nil
        case .warn: return .orange
        case .over: return .red
        }
    }

    private func budgetHelp(_ b: BudgetStatus) -> String {
        switch b.level {
        case .off: return "Total token usage across visible sessions"
        case .ok, .warn: return "Estimated spend: \(b.progressLabel ?? "") budget"
        case .over: return "Over budget: \(b.progressLabel ?? "")"
        }
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
            // Within a project, most-recently-active session first. `updatedAt` is
            // bumped on every output flush, so live sessions float to the top as they
            // work; ties (and identical timestamps) fall back to createdAt for stable
            // order.
            let ordered = sessions.sorted {
                $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.createdAt > $1.createdAt
            }
            return FolderGroup(
                cwd: cwd,
                name: (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent,
                sessions: ordered,
                running: ordered.filter { model.isLive($0.id) }.count)
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

    /// Collapse any folder we haven't seen before, so projects are minimized by
    /// default. Already-seen folders keep whatever expand/collapse state the user set.
    private func collapseNewFolders(_ cwds: [String]) {
        for cwd in cwds where !seenFolders.contains(cwd) {
            seenFolders.insert(cwd)
            collapsedFolders.insert(cwd)
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
                .focused($searchFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                // ⌃F (via `focusSessionSearch`) jumps focus straight to the filter.
                .onChange(of: model.sessionSearchFocusToken) { _, _ in searchFocused = true }
            ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(groups) { group in
                    Section {
                        if !collapsedFolders.contains(group.cwd) {
                            sessionList(group)
                        }
                    } header: {
                        FolderHeader(group: group, collapsed: collapsedFolders.contains(group.cwd)) {
                            // Animated so the section's rows slide in/out instead of snapping.
                            withAnimation(.easeOut(duration: 0.18)) {
                                if collapsedFolders.contains(group.cwd) {
                                    collapsedFolders.remove(group.cwd)
                                } else {
                                    collapsedFolders.insert(group.cwd)
                                }
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
                                .background(Color.appSurface.opacity(0.8))
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
            // Minimize projects by default: collapse each folder the first time it
            // appears, then leave the user's manual toggles alone (juancode).
            .onChange(of: groups.map(\.cwd)) { _, cwds in collapseNewFolders(cwds) }
            .onAppear { collapseNewFolders(groups.map(\.cwd)) }
            // Keep the moved selection on-screen (g/G can jump far).
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
            }
            }
            Divider()
            // Always-visible "add a project" entry point: opens the New Session
            // sheet (its Choose… picker is how a folder becomes a sidebar project),
            // so adding a project doesn't depend on the toolbar "+" or a shortcut.
            Button { model.showingNewSession = true } label: {
                Label("New project…", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .help("Start a session in any folder — it appears here as a project")
            if let total = totalUsage, let label = total.badgeLabel {
                Divider()
                // Colour + budget progress when a cost budget is set (juancode-qoc):
                // amber past the warn threshold, red at/over budget.
                let budget = model.budgetStatus(forSpend: total.costUsd)
                let tint = budgetTint(budget.level)
                HStack(spacing: 4) {
                    Text("Total").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if let progress = budget.progressLabel {
                        Text(progress)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(tint ?? .secondary)
                    }
                    Text(label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(tint ?? .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help(budgetHelp(budget)
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
        .background(Color.appSurface)
        .onAppear { model.loadExternalSessions(); model.navOrder = visibleOrderedIDs }
        .toolbar {
            ToolbarItem {
                let anyExpanded = groups.contains { !collapsedFolders.contains($0.cwd) }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        collapsedFolders = anyExpanded ? Set(groups.map(\.cwd)) : []
                    }
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
                Button { model.showingKillPort = true } label: { Image(systemName: "powerplug") }
                    .help("Kill Port — free up a stuck local dev port")
                    .clickCursor()
            }
            ToolbarItem {
                // Visible Keep Awake indicator + quick toggle (also on View menu, ⌃⇧A).
                // Filled + tinted while the idle-sleep assertion is held; dimmed cup
                // when off. So you can always tell at a glance whether sessions are
                // protected from idle sleep.
                Button { model.keepAwake.toggle() } label: {
                    Image(systemName: model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(model.keepAwake ? Color.accentColor : Color.secondary)
                }
                .help(model.keepAwake
                      ? "Keep Awake is on — the Mac won't idle-sleep. Click to turn off (⌃⇧A)"
                      : "Keep Awake is off — click to stop the Mac idle-sleeping while sessions run (⌃⇧A)")
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
            Button { withAnimation(.easeOut(duration: 0.18)) { _ = expandedFolders.insert(group.cwd) } } label: {
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
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, meta in
                        // Match the List path's minimal inter-row hairline.
                        if index > 0 {
                            Divider().overlay(Color.appHairline(0.12)).padding(.horizontal, 8)
                        }
                        scrollRow(meta)
                    }
                }
            }
            .frame(maxHeight: CGFloat(folderScrollMaxHeight))
            // Drag the divider down to grow the box / up to shrink it (persisted).
            DragResizeHandle(axis: .horizontal, value: $folderScrollMaxHeight,
                             min: 120, max: 800, invert: false)
            Button { withAnimation(.easeOut(duration: 0.18)) { _ = expandedFolders.remove(cwd) } } label: {
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
            // A minimal hairline between session rows for visual separation.
            .listRowSeparator(.visible)
            .listRowSeparatorTint(Color.appHairline(0.12))
            .onAppear { if meta.worktreePath != nil { model.loadFolderGitState(meta.cwd) } }
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
            .onAppear { if meta.worktreePath != nil { model.loadFolderGitState(meta.cwd) } }
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
                          atRisk: !external && model.workAtRisk(forSession: meta) != nil,
                          worktreeBranch: meta.worktreePath != nil ? model.folderGitState(meta.cwd)?.branch : nil,
                          onResume: external ? { model.importExternalSession(meta.id) } : nil,
                          selected: model.selection == meta.id)
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
            if let tracked = model.trackedPr(forSession: meta.id) {
                Divider()
                Button("Untrack PR #\(tracked.number)") { model.untrackPr(tracked.id) }
            }
            if let trackedIssue = model.trackedIssue(forSession: meta.id) {
                Divider()
                Button("Untrack issue \(trackedIssue.identifier)") { model.untrackIssue(trackedIssue.id) }
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
    @State private var confirmingCloseAll = false
    @State private var plusHovering = false

    /// Folder tooltip: full path, plus the per-project spend rollup when known so
    /// the cost stays discoverable without crowding the header (juancode-341).
    private var folderHelp: String {
        guard let cost = folderCost else { return group.cwd }
        return "\(group.cwd)\n\(cost) estimated across this project"
    }

    /// Sessions in this project with a pending turn-end notification.
    private var unreadCount: Int {
        group.sessions.filter { model.unreadSessions.contains($0.id) }.count
    }

    /// At-risk work rolled up per CHECKOUT, not per session — dozens of sessions
    /// share one checkout, so counting sessions showed absurd numbers ("97" for
    /// one dirty branch, juancode-64z). `main` is the repo root's own risk entry
    /// (uncommitted/unpushed on the folder itself); `worktrees` counts distinct
    /// at-risk linked worktrees under this repo, including orphaned ones.
    private var atRiskRoots: (main: WorkAtRisk?, worktrees: Int) {
        let root = WorkAtRiskScan.normalize(group.cwd)
        var seen = Set<String>()
        var main: WorkAtRisk?
        var worktrees = 0
        func take(_ r: WorkAtRisk) {
            guard seen.insert(r.path).inserted else { return }
            if r.path == root { main = r } else { worktrees += 1 }
        }
        for r in model.workAtRiskList where r.path == root || r.repoRoot == root { take(r) }
        // Sessions whose at-risk root isn't tied to this repo root (e.g. a cwd in
        // a subdirectory the worktree listing doesn't know) still count once.
        for s in group.sessions {
            if let r = model.workAtRisk(forSession: s) { take(r) }
        }
        return (main, worktrees)
    }

    /// Tooltip for the main-checkout badge: what exactly is at risk there.
    private func mainRiskHelp(_ r: WorkAtRisk) -> String {
        var parts: [String] = []
        if r.dirtyFiles > 0 { parts.append("\(r.dirtyFiles) uncommitted file(s)") }
        if r.ahead > 0 {
            parts.append("\(r.ahead) unpushed commit(s)\(r.noUpstream ? " (no upstream)" : "")")
        }
        let what = parts.joined(separator: ", ")
        let branch = r.branch.map { " on \($0)" } ?? ""
        return "Main checkout: \(what)\(branch)"
    }

    /// Own sessions we can close in bulk. Discovered/external sessions aren't ours
    /// to delete (their row only offers "Resume"), so they're excluded.
    private var closableSessions: [SessionMeta] {
        group.sessions.filter { !model.isExternal($0.id) }
    }

    /// Per-project spend rollup (juancode-qoc): summed estimated cost across this
    /// folder's sessions, as a short "$0.42" — nil when no session reports a cost.
    private var folderCost: String? {
        SessionUsageFormat.cost(group.sessions.aggregateUsage()?.costUsd)
    }

    /// Open bd issues in this folder — mirrors `FolderIssues`' own filter so we can
    /// decide whether the second (metadata) line has anything to show.
    private var openIssueCount: Int {
        guard let r = model.beads(group.cwd), r.available else { return 0 }
        return r.issues.filter { $0.status != "closed" }.count
    }

    /// Open PRs in this folder — mirrors `FolderPrs`, same purpose as above.
    private var openPrCount: Int {
        guard let r = model.prs(group.cwd), r.available else { return 0 }
        return r.prs.count
    }

    /// Whether the metadata line has any signal. Keeps an idle folder a single line.
    private func showsMeta(_ risk: (main: WorkAtRisk?, worktrees: Int)) -> Bool {
        group.running > 0 || unreadCount > 0 || risk.main != nil || risk.worktrees > 0
            || openIssueCount > 0 || openPrCount > 0
    }

    var body: some View {
        // Two-line layout (juancode-…): name gets its own line so it no longer
        // truncates behind the badge cluster; all counts drop to a second line.
        let risk = atRiskRoots
        VStack(alignment: .leading, spacing: 5) {
            // Line 1: collapse toggle (chevron + name, full-width clickable) + the
            // per-folder "+" agent menu.
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(group.name)
                            .font(.system(size: 15, weight: .semibold))
                            // Explicit primary: section-header text otherwise renders
                            // in the dimmed secondary gray, which read as disabled.
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(folderHelp)
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
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.appHairline(plusHovering ? 0.14 : 0)))
                }
                .buttonStyle(.plain)
                .help("New session in \(group.cwd)")
                .clickCursor()
                .onHover { plusHovering = $0 }
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
            }
            // Line 2: quiet metadata cluster — a single 10pt style, semantic color only
            // where it's a signal. Only rendered when something is present.
            if showsMeta(risk) {
                HStack(spacing: 8) {
                    // Current branch on the main checkout — the project-level "where am
                    // I" signal. Leads the line; hidden on a detached HEAD / non-git dir.
                    if let branch = model.folderGitState(group.cwd)?.branch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                            Text(branch)
                                .font(.system(size: 10, weight: .medium).monospaced())
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .help("Current branch on the main checkout")
                    }
                    // Running: a green dot + count. No "running" copy — in context the
                    // green dot is the signal.
                    if group.running > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("\(group.running)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        .help("\(group.running) running session(s)")
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
                    // Work-at-risk roll-up per checkout, not per session (juancode-64z):
                    // yellow pencil = the main checkout itself holds uncommitted/unpushed
                    // work (count: dirty files + unpushed commits); orange warning = how
                    // many distinct WORKTREES hold at-risk work.
                    if let main = risk.main {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 9))
                            Text("\(main.dirtyFiles + main.ahead)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(.yellow)
                        .help(mainRiskHelp(main))
                    }
                    if risk.worktrees > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                            Text("\(risk.worktrees)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(.orange)
                        .help("\(risk.worktrees) worktree(s) here with uncommitted or unpushed work")
                    }
                    Spacer(minLength: 0)
                    FolderIssues(cwd: group.cwd)
                    FolderPrs(cwd: group.cwd)
                }
                .padding(.leading, 15) // align under the name, past the chevron
            }
        }
        // Full-width project bar: a subtle raised fill that spans the whole sidebar
        // (edge to edge, no rounded inset) for clear contrast against the session
        // rows, with a hairline underline separating it from the sessions below.
        // Trailing is wider than leading: the outer -10 stretch below eats 10pt of
        // it, leaving ~8pt of visible inset so the badge cluster doesn't sit under
        // the splitter/scrollbar.
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appHairline(0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appHairline(0.12)).frame(height: 1)
        }
        // `.listRowInsets(EdgeInsets())` (at the call site) removes the row's own
        // insets, but the sidebar list style still pads row content ~10pt per side
        // for its rounded-selection look — the gap left of the bar. Negative
        // padding outside the fill stretches it to the true sidebar edges.
        .padding(.horizontal, -10)
        .contextMenu {
            if !closableSessions.isEmpty {
                Button("Close All \(closableSessions.count) Session\(closableSessions.count == 1 ? "" : "s")",
                       role: .destructive) { confirmingCloseAll = true }
            }
        }
        .confirmationDialog("Close all sessions in \(group.name)?",
                            isPresented: $confirmingCloseAll, titleVisibility: .visible) {
            Button("Close \(closableSessions.count) Session\(closableSessions.count == 1 ? "" : "s")",
                   role: .destructive) {
                model.closeSessions(closableSessions.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let running = closableSessions.filter { model.isLive($0.id) }.count
            Text(running > 0
                 ? "\(running) of these are still running. This stops every agent here and removes the sessions."
                 : "This removes every session in this project.")
        }
        .onAppear { model.loadPrs(group.cwd); model.loadBeads(group.cwd); model.loadFolderGitState(group.cwd) }
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
                // Checks as an icon + passed/total fraction (coloured by rollup
                // status), and, when any, the number of unresolved review threads.
                // Hover for the full passing/failing wording.
                HStack(spacing: 3) {
                    Image(systemName: checkIcon).font(.system(size: 9))
                    Text(checksText).font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(checkColor)
                .help(checkLabel)
                if pr.unresolvedComments > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 8))
                        Text("\(pr.unresolvedComments)").font(.system(size: 10))
                    }
                    .foregroundStyle(.orange)
                    .help("\(pr.unresolvedComments) unresolved comment\(pr.unresolvedComments == 1 ? "" : "s")")
                }
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

    /// Status-adaptive check glyph paired with the fraction. Colour comes from
    /// `checkColor`.
    private var checkIcon: String {
        switch pr.checks {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .none: return "minus.circle"
        }
    }

    /// The check summary shown in the row: "passed/total" (e.g. "4/11"), or "No
    /// checks" when there are none. Colour comes from `checkColor`; the full
    /// passing/failing wording lives in `checkLabel` (tooltip).
    private var checksText: String {
        pr.checkCount == 0 ? "No checks" : "\(pr.passedCount)/\(pr.checkCount)"
    }

    private var checkLabel: String {
        guard pr.checkCount > 0 else { return "No checks" }
        let base: String
        switch pr.checks {
        case .passing: base = "All checks passing"
        case .failing: base = "Checks failing"
        case .pending: base = "Checks running"
        case .none: base = "No checks"
        }
        return "\(base) — \(pr.passedCount)/\(pr.checkCount) passed"
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
    /// This session's folder holds uncommitted/unpushed work (juancode-rxu) — shows
    /// a small warning capsule on the trailing edge.
    var atRisk: Bool = false
    /// Branch this session's worktree is on, when it runs in a juancode-owned git
    /// worktree (`meta.worktreePath != nil`). Drives the branch label + glyph in the
    /// subtitle so worktree rows read distinctly from main-checkout rows. Nil for
    /// non-worktree sessions or until the branch is loaded.
    var worktreeBranch: String? = nil
    /// Resume action for an external row; the row is otherwise non-interactive.
    var onResume: (() -> Void)? = nil
    /// Whether this row is the current selection — drives showing the external
    /// resume affordance alongside hover.
    var selected: Bool = false

    @State private var hovering = false

    var body: some View {
        // firstTextBaseline so the status dot and any trailing ornament sit on the
        // title line — a two-line row (title + usage subtitle) reads as one unit.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIndicator
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title).lineLimit(1)
                    .font(.system(size: 13, weight: unread ? .semibold : .regular))
                if isWorktree || !subtitle.isEmpty {
                    HStack(spacing: 3) {
                        // A branch glyph marks a worktree session — the fastest way to
                        // tell it apart from a main-checkout row.
                        if isWorktree {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(usageHelp)
                }
            }
            Spacer(minLength: 6)
            trailingOrnament
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    /// At most one tracking capsule plus (for external rows) a hover-revealed
    /// resume button. Usage moved into the subtitle, so the trailing edge stays
    /// quiet (juancode-341).
    @ViewBuilder
    private var trailingOrnament: some View {
        if showPr, let t = tracked {
            prCapsule(t)
        } else if showIssue, let ti = trackedIssue {
            issueCapsule(ti)
        }
        // At-risk warning only on worktree rows: an isolated worktree's uncommitted
        // work can be orphaned/forgotten, so it's worth flagging. Main-checkout
        // sessions all share one checkout — the dirty state is just the current
        // branch's normal work, and the folder header already rolls that up.
        if atRisk, !external, isWorktree {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help("Uncommitted or unpushed work in this worktree")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
        }
        if external, let onResume, hovering || selected {
            Button(action: onResume) {
                Image(systemName: "play.circle").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("From your terminal — resume in juancode")
            .clickCursor()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
        }
    }

    private func prCapsule(_ t: TrackedPr) -> some View {
        var help = "Tracking PR #\(t.number) — \(t.state.rawValue)\nClick to open in browser"
        // When an issue is also tracked but folded away, keep its id discoverable.
        if let ti = trackedIssue, !showIssue {
            help += "\nAlso tracking \(ti.identifier) — \(ti.state.rawValue)"
        }
        // A button so the click opens the PR without also selecting the row.
        return Button {
            if let url = URL(string: t.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 8))
                Text("#\(t.number)").font(.system(size: 9, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(trackColor(t.state).opacity(0.2))
            .foregroundStyle(trackColor(t.state))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help(help)
    }

    private func issueCapsule(_ ti: TrackedIssue) -> some View {
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

    /// Which single tracking capsule to show. Prefer whichever is in a non-watching
    /// (active) state; when a PR and an issue are both present, the PR wins unless
    /// only the issue is active — the loser is folded into the survivor's tooltip.
    private var prActive: Bool { tracked.map { $0.state != .watching } ?? false }
    private var issueActive: Bool { trackedIssue.map { $0.state != .watching } ?? false }
    private var showPr: Bool {
        guard tracked != nil else { return false }
        guard trackedIssue != nil else { return true }
        return !(issueActive && !prActive)
    }
    private var showIssue: Bool { trackedIssue != nil && !showPr }

    private var isWorktree: Bool { meta.worktreePath != nil }

    private var subtitle: String {
        // Non-worktree rows: the folder/project name is redundant (the row sits under
        // its project header), so show only usage.
        guard isWorktree else { return meta.usage?.badgeLabel ?? "" }
        // Worktree rows show the branch (e.g. `juancode/48e86fc1`) rather than the
        // worktree dir's bare hash, so the row reads meaningfully. Falls back to the
        // dir name until the branch loads (or on a detached HEAD).
        let base = worktreeBranch ?? (meta.cwd as NSString).lastPathComponent
        if let label = meta.usage?.badgeLabel { return "\(base) · \(label)" }
        return base
    }

    /// Detailed usage breakdown for the subtitle tooltip (was the trailing badge's
    /// `.help`). Falls back to the plain subtitle when no usage is reported.
    private var usageHelp: String {
        guard let u = meta.usage, u.totalTokens > 0 else { return subtitle }
        var lines = [
            "\(SessionUsageFormat.tokens(u.totalTokens)) tokens total",
            "in \(SessionUsageFormat.tokens(u.inputTokens)) · out \(SessionUsageFormat.tokens(u.outputTokens))",
            "cache read \(SessionUsageFormat.tokens(u.cacheReadTokens)) · write \(SessionUsageFormat.tokens(u.cacheWriteTokens))",
        ]
        if let c = SessionUsageFormat.cost(u.costUsd) { lines.append("est. cost \(c)") }
        return lines.joined(separator: "\n")
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
    /// Width of the right-side panel, persisted once the user drags its edge. Nil =
    /// never resized → the screen-size-proportional default applies (juancode-it1).
    @AppStorage("session.sidePanel.width") private var storedPanelWidth: Double?
    /// Persisted height of the bottom terminal panel in the split.
    @AppStorage("session.bottomPanel.height") private var bottomHeight: Double = 240

    /// Effective panel width: the user's persisted width if they ever dragged the
    /// edge, else ~32% of the window (capped — the cap bounds the auto default
    /// only; a manual drag can go wider).
    private var panelWidth: Double {
        storedPanelWidth ?? PanelAutoSize.width(window: model.windowWidth,
                                                fraction: 0.32, min: 420, max: 640)
    }

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
                    model.refreshTerminal()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh terminal — rebuild and replay scrollback to fix a corrupted / garbled render")
                .clickCursor()
                Button {
                    model.resyncTerminalGeometry()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Recalculate terminal geometry — re-fit the grid if a resize left it mis-sized (⌃⇧R)")
                .clickCursor()
                Button {
                    model.toggleBottomTerminal()
                } label: {
                    Image(systemName: model.bottomTerminalShown ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle")
                }
                .help(model.bottomTerminalShown ? "Hide the terminal panel (⌃T)" : "Show the terminal panel (⌃T)")
                .clickCursor()
                Button {
                    // The panel floats over the terminal (see the overlay below), so
                    // toggling it never relayouts the terminal — no transition gate.
                    // Animated: it slides in from the right edge instead of popping.
                    withAnimation(.easeOut(duration: 0.18)) { panelShown.toggle() }
                } label: {
                    Image(systemName: panelShown ? "sidebar.right" : "sidebar.squares.right")
                }
                .help(panelShown ? "Hide the Changes / Issues panel" : "Show the Changes / Issues panel")
                .clickCursor()
            }
            .padding(8)
            Divider()
            VStack(spacing: 0) {
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.bottomTerminalShown {
                    // previewOnly: this divider borders the live terminal panes
                    // (main + bottom). Committing the size live reflows the CLI's
                    // TUI on every drag frame, interleaving partial redraws into the
                    // scrollback buffer permanently. Preview the edge during the drag
                    // and resize once on release for a single clean repaint.
                    DragResizeHandle(axis: .horizontal, value: $bottomHeight, min: 120, max: 720,
                                     previewOnly: true)
                    BottomTerminalPanel(cwd: meta.cwd)
                        .frame(height: CGFloat(bottomHeight))
                }
            }
            // Breathing room so the terminal isn't glued to the window edges. Constant
            // on both sides: nothing about the side panel's visibility may change the
            // terminal's layout (see the overlay note below).
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The Changes/Issues panel floats OVER the terminal instead of splitting
            // the space with it. Squeezing the terminal ~400pt narrower rewraps the
            // whole scrollback and forces the CLI's TUI to redraw across a huge width
            // jump — no SIGWINCH choreography made that clean (juancode-1th.2,
            // juancode-qxb). Overlaying keeps the pty grid untouched, so toggling or
            // drag-resizing the panel can never disturb the terminal render.
            .overlay(alignment: .trailing) {
                if panelShown {
                    HStack(spacing: 0) {
                        // Live resize is fine here: the drag moves only the floating
                        // panel's edge, never the terminal grid. Writing through the
                        // binding persists the width — manual wins over the auto default.
                        DragResizeHandle(axis: .vertical,
                                         value: Binding(get: { panelWidth },
                                                        set: { storedPanelWidth = $0 }),
                                         min: 280, max: .infinity)
                        sidePanel
                            .frame(width: CGFloat(panelWidth))
                    }
                    .background(Color.appPanel)
                    .shadow(color: .black.opacity(0.45), radius: 14, x: -6, y: 0)
                    // Slide in/out over the terminal — safe to animate because the
                    // panel is an overlay: the pty grid never reflows.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
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
            // The `.id` folds in `terminalRefreshToken`: bumping it (the Refresh
            // button) recreates the view, which re-subscribes with replay:true and
            // repaints the full scrollback — the hard-refresh escape hatch.
            if TerminalBackendChoice.useGhostty {
                GhosttyLive(session: session,
                            focusToken: model.terminalFocusToken,
                            resyncToken: model.terminalResyncToken,
                            autoFocusOnAppear: !model.suppressTerminalAutoFocus)
                    .id(TerminalIdentity(session: session, refresh: model.terminalRefreshToken))
            } else {
                SwiftTermLive(session: session,
                              focusToken: model.terminalFocusToken,
                              resyncToken: model.terminalResyncToken,
                              autoFocusOnAppear: !model.suppressTerminalAutoFocus)
                    .id(TerminalIdentity(session: session, refresh: model.terminalRefreshToken))
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
