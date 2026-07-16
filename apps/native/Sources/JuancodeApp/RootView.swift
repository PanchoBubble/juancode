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
        // Column visibility is bridged through AppModel so ⌃S can toggle the projects
        // sidebar; the native toolbar toggle writes back through the same binding.
        return NavigationSplitView(columnVisibility: Binding(
            get: { model.projectsSidebarVisible ? .all : .detailOnly },
            set: { model.projectsSidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarIdeal)
        } detail: {
            DetailView()
        }
        // Publish the window content width; drives all auto panel defaults.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .preferredColorScheme(model.themePreference.colorScheme)
        .background(WindowBackground(color: .appWindow) { model.hostWindow = $0 })
        // Window-scoped key monitor for vim sidebar nav + ⌃H/⌃L pane focus (juancode-vgm).
        .background(PaneNavInstaller(model: model, oracle: oracle, shortcuts: shortcuts).frame(width: 0, height: 0))
        // Global command bar (juancode-6sw): Oracle, global Issues, Tracked PRs and
        // Worktrees live in the window toolbar — reachable from any session.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Slimmed top bar (juancode-v4ep): notifications, the Oracle AI, an
                // AI-settings prompt, and a Tools popover. Everything else moved —
                // Keep Awake / Recurring Tasks / Worktrees / Kill Port / MCP status
                // into Tools; the pencil onto session-row hover; Tracked Issues into
                // the sidebar; Appearance into the ⌘, Settings window.
                NotificationsBell()
                Button { oracle.open(tab: .chat) } label: {
                    Label("Oracle", systemImage: "sparkles")
                }
                .help("Oracle — global orchestration (⌃Space)")
                .clickCursor()
                Button { model.showingSettingsAI = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Ask AI to change your settings")
                .clickCursor()
                ToolsMenu()
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
        .sheet(isPresented: $model.showingJumpPalette) {
            JumpPaletteView()
        }
        .sheet(isPresented: $model.showingQuickOpen) {
            QuickOpenView()
        }
        .sheet(isPresented: $model.showingSessionTemplates) {
            SessionTemplatesView()
        }
        .sheet(isPresented: $model.showingKillPort) {
            KillPortSheet()
        }
        .sheet(isPresented: $model.showingStatus) {
            StatusPanel()
        }
        .sheet(isPresented: $model.showingSettingsAI) {
            SettingsAIView()
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
    /// Called with the resolved host window, so the model can grow it for the
    /// bottom terminal panel.
    var onResolve: ((NSWindow) -> Void)? = nil

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
        onResolve?(window)
    }
}

/// An `NSScrollView` that keeps its scroll wheel events to itself: within bounds it
/// scrolls natively, but once pinned at the top/bottom it swallows the gesture instead
/// of forwarding it up the responder chain to an enclosing scroll view. Nesting a
/// plain SwiftUI `ScrollView` inside the sidebar `List` bubbled overscroll to the List,
/// which yanked the whole sidebar ("pushes content in a weird way"). It also sizes
/// itself: intrinsic height = content height, capped at `maxContentHeight`, so a short
/// folder stays short and a long one scrolls internally.
private final class ContainingScrollView: NSScrollView {
    var maxContentHeight: CGFloat = 220 {
        didSet { if maxContentHeight != oldValue { invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: NSSize {
        let contentHeight = documentView?.fittingSize.height ?? 0
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: min(max(contentHeight, 0), maxContentHeight))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { super.scrollWheel(with: event); return }
        let maxY = max(0, doc.frame.height - contentView.bounds.height)
        // Content fits — nothing to scroll here, so hand the gesture to the parent List.
        if maxY <= 0 { nextResponder?.scrollWheel(with: event); return }
        let y = contentView.bounds.origin.y
        let dy = event.scrollingDeltaY // > 0 scrolls toward the top (natural scrolling)
        let atTop = y <= 0.5, atBottom = y >= maxY - 0.5
        // Pinned at the edge the gesture pushes past: forward it up the responder chain so
        // the sidebar List keeps scrolling instead of getting stuck. Everything else
        // scrolls natively via super.
        if (atTop && dy > 0) || (atBottom && dy < 0) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// SwiftUI wrapper around `ContainingScrollView`, hosting arbitrary SwiftUI content.
/// Height is driven by the content (capped at `maxHeight`), so `.frame` isn't needed.
private struct ContainedScroll<Content: View>: NSViewRepresentable {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ContainingScrollView {
        let scroll = ContainingScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        context.coordinator.hosting = hosting
        scroll.maxContentHeight = maxHeight
        return scroll
    }

    func updateNSView(_ nsView: ContainingScrollView, context: Context) {
        context.coordinator.hosting?.rootView = AnyView(content)
        nsView.maxContentHeight = maxHeight
        nsView.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var hosting: NSHostingView<AnyView>? }
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

/// `projectCwd(for:)` (the worktree→repo folding used for sidebar grouping) now
/// lives in JuancodeCore so the store's retention cap can share it.

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

/// Top-bar "Tools" popover (juancode-v4ep): the utilities that used to be their own
/// toolbar buttons — Keep Awake, Recurring Tasks, Worktrees, Kill Port, and Auth &
/// MCP status. The wrench icon turns orange when a worktree holds at-risk work, so
/// the old worktree warning stays visible at a glance without opening the popover.
private struct ToolsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var atRisk: Bool { !model.workAtRiskList.isEmpty }

    var body: some View {
        Button { showing = true } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .foregroundStyle(atRisk ? Color.orange : Color.primary)
        .help(atRisk
              ? "\(model.workAtRiskList.count) folder(s) with uncommitted or unpushed work"
              : "Tools — keep awake, recurring tasks, worktrees, kill port, MCP status")
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // Keep Awake is a toggle, so it shows its live state rather than
                // dismissing — the rest open a sheet and close the popover.
                Button { model.keepAwake.toggle() } label: {
                    row(model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer",
                        "Keep Awake",
                        tint: model.keepAwake ? Color.accentColor : nil,
                        trailing: model.keepAwake ? "On" : "Off")
                }
                .buttonStyle(.plain).clickCursor()
                .help("Block the Mac from idle-sleeping while sessions run (⌃⇧A)")
                Divider().padding(.vertical, 2)
                toolButton("repeat", "Recurring Tasks",
                           trailing: model.recurringTasks.isEmpty ? nil : "\(model.recurringTasks.count)") {
                    model.showingRecurringTasks = true
                }
                toolButton(atRisk ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.minus",
                           "Worktrees", tint: atRisk ? Color.orange : nil,
                           trailing: atRisk ? "\(model.workAtRiskList.count)" : nil) {
                    model.showingWorktrees = true
                    model.loadWorktrees()
                }
                toolButton("powerplug", "Kill Port") { model.showingKillPort = true }
                toolButton("shield.lefthalf.filled", "Auth & MCP status") { model.showingStatus = true }
            }
            .padding(6)
            .frame(width: 240)
        }
    }

    /// A popover row that opens a sheet then dismisses the popover.
    @ViewBuilder
    private func toolButton(_ systemImage: String, _ title: String, tint: Color? = nil,
                            trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showing = false
        } label: {
            row(systemImage, title, tint: tint, trailing: trailing)
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private func row(_ systemImage: String, _ title: String, tint: Color? = nil,
                     trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 12))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8).padding(.vertical, 6)
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
    /// The scroll-box session row currently under a drag (by id), for the drop
    /// highlight. The native List rows get theirs from `.onMove` for free.
    @State private var sessionDropTarget: String?

    /// How many session rows a folder shows before offering "Load more".
    private let folderPreviewCount = 5
    /// Max height of an expanded folder's scrollable session box (~5 rows at the
    /// 220 default). User-resizable via the drag handle under the box; persisted.
    @AppStorage("session.folderScroll.maxHeight") private var folderScrollMaxHeight: Double = 220
    /// The session currently being renamed (drives the rename alert).
    @State private var renaming: SessionMeta?
    @State private var renameText = ""
    /// Whether the session list holds keyboard focus, for vim-style nav (juancode-vgm).
    @FocusState private var listFocused: Bool
    /// Whether the "Filter sessions…" field holds focus, so ⌃F can jump to it.
    @FocusState private var searchFocused: Bool

    /// How many archived sessions exist (for the toggle label / visibility).
    private var archivedCount: Int { model.sessions.filter(\.archived).count }

    /// Sessions that would show with no filter applied (same visibility rules as
    /// `groups`, minus the query) — the denominator for the "showing N of M" hint.
    private var unfilteredVisibleCount: Int {
        let nonOracle = (model.sessions + model.externalSessions).filter { $0.cwd != OraclePaths.controlDir }
        let inWorkspace = nonOracle.filter { Config.isUnderWorkspaceRoot($0.cwd) }
        return (showArchived ? inWorkspace : inWorkspace.filter { !$0.archived }).count
    }

    /// Sessions currently shown after the filter is applied.
    private func filteredVisibleCount(_ groups: [FolderGroup]) -> Int {
        groups.reduce(0) { $0 + $1.sessions.count }
    }

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
    ///
    /// A method (not a computed property) so `body` computes it exactly once into a
    /// local and threads that value through every consumer, instead of re-deriving
    /// the whole filter/group/sort on each of the ~6 references per body eval
    /// (juancode-5qw.8).
    private func makeGroups() -> [FolderGroup] {
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
            // Within a project: sessions needing action (waiting for a reply,
            // finished-but-unseen) bubble to the top; the rest hold the user's
            // drag order, with unplaced ones resting where the stable sort puts
            // them (live newest-first, dead sinking — juancode-05u). Bubbling is
            // temporary: the persisted order is untouched, so a handled session
            // falls back to its manual slot.
            let slots = manualSlots(cwd)
            let ordered = sessions.sorted {
                manualWithBubblePrecedes(manualSortKey($0, slots: slots),
                                         manualSortKey($1, slots: slots))
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

    /// The user's manual slot per session id for one project (empty when the
    /// user never dragged in that folder).
    private func manualSlots(_ cwd: String) -> [String: Int] {
        let order = model.sessionOrder[cwd] ?? []
        return Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// One session's attention bucket, mirroring the row glyph exactly.
    private func attention(_ meta: SessionMeta) -> SessionAttention {
        sessionAttention(live: model.isLive(meta.id),
                         activity: model.activity(meta.id),
                         unseenDone: model.unseenCompletions.contains(meta.id))
    }

    /// The manual-order sort inputs for one session: its attention (bubbling +
    /// dead-sink), timestamps, and its slot in the user's persisted drag order.
    private func manualSortKey(_ meta: SessionMeta, slots: [String: Int]) -> ManualSortKey {
        ManualSortKey(
            key: SessionSortKey(attention: attention(meta),
                                updatedAt: meta.updatedAt, createdAt: meta.createdAt),
            manualIndex: slots[meta.id],
            id: meta.id)
    }

    /// Collapse any folder we haven't seen before, so projects are minimized by
    /// default. Already-seen folders keep whatever expand/collapse state the user set.
    ///
    /// The mutation is deferred one main-actor turn: both callers fire while the
    /// sidebar List's backing NSTableView is mid-update (`onAppear` runs during the
    /// table's initial row pass, `onChange` inside the same view-update transaction),
    /// and collapsing restructures the list — mutating synchronously there makes the
    /// table apply row removals reentrantly ("reentrant operation in its NSTableView
    /// delegate").
    private func collapseNewFolders(_ cwds: [String]) {
        let new = cwds.filter { !seenFolders.contains($0) }
        guard !new.isEmpty else { return }
        Task { @MainActor in
            seenFolders.formUnion(new)
            collapsedFolders.formUnion(new)
        }
    }

    /// Reorder projects by drag-and-drop: drop `dragged`'s header onto `target`'s to
    /// place it just before `target`. Persists the full current order so subsequent
    /// drags are stable.
    private func reorderProjects(moving dragged: String, onto target: String) {
        guard dragged != target else { return }
        var order = makeGroups().map(\.cwd)
        guard let from = order.firstIndex(of: dragged) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: to)
        // Spring so the sections slide into their new positions instead of
        // snapping — `groups` re-sorts deterministically off `projectOrder` and
        // `FolderGroup.id == cwd` is stable, so SwiftUI interpolates the move.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            model.projectOrder = order
        }
    }

    /// Persist a new manual order for `group` after a drag. `displayedAfterMove`
    /// is the on-screen order with the move already applied; the persisted order
    /// derives from the resting order instead, so rows that were only bubbled up
    /// by attention keep their manual slot rather than being captured at the top.
    private func persistSessionOrder(_ group: FolderGroup, displayedAfterMove: [String], moved id: String) {
        let slots = manualSlots(group.cwd)
        let resting = group.sessions
            .sorted {
                manualRestingPrecedes(manualSortKey($0, slots: slots),
                                      manualSortKey($1, slots: slots))
            }
            .map(\.id)
        let bubbled = Set(group.sessions
            .filter { attentionBubblesAboveManualOrder(attention($0)) }
            .map(\.id))
        let order = manualOrderAfterMove(
            displayed: displayedAfterMove, resting: resting, bubbled: bubbled, moved: id)
        // Deferred one main-actor turn: .onMove fires from inside the backing
        // NSTableView's drag handling, and this mutation restructures the list
        // mid-update — same reentrancy class as collapseNewFolders above.
        Task { @MainActor in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                model.setSessionOrder(order, forProject: group.cwd)
            }
        }
    }

    /// `.onMove` handler for the List's session rows. `shown` is the ForEach's
    /// data — the whole group or the preview prefix — and `from`/`to` are in its
    /// coordinates; rows hidden behind "Load more" keep their tail order.
    private func moveSessions(in group: FolderGroup, shown: [SessionMeta], from: IndexSet, to: Int) {
        guard let first = from.first else { return }
        var shownIds = shown.map(\.id)
        let movedId = shownIds[first]
        shownIds.move(fromOffsets: from, toOffset: to)
        let displayed = shownIds + group.sessions.map(\.id).dropFirst(shown.count)
        persistSessionOrder(group, displayedAfterMove: displayed, moved: movedId)
    }

    /// Scroll-box drop handler: place `dragged` just before `target`, the same
    /// gesture as the project headers. Returns false (drop rejected) for ids not
    /// in this group — cross-project drags don't reorder anything.
    @discardableResult
    private func reorderSessions(in group: FolderGroup, moving dragged: String, onto target: String) -> Bool {
        guard dragged != target else { return false }
        var displayed = group.sessions.map(\.id)
        guard let from = displayed.firstIndex(of: dragged) else { return false }
        displayed.remove(at: from)
        guard let to = displayed.firstIndex(of: target) else { return false }
        displayed.insert(dragged, at: to)
        persistSessionOrder(group, displayedAfterMove: displayed, moved: dragged)
        return true
    }

    /// Selectable session IDs in on-screen order (folders flattened, collapsed folders
    /// and clipped previews respected, externals excluded) — what j/k steps through.
    /// Published into `model.navOrder` so the keyboard monitor can move the selection.
    private func visibleOrderedIDs(from groups: [FolderGroup]) -> [String] {
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
        // Derive the grouped/sorted list once per body eval and thread it through
        // every consumer below, instead of re-running the filter/group/sort on each
        // reference (juancode-5qw.8).
        let groups = makeGroups()
        let visibleIDs = visibleOrderedIDs(from: groups)
        return VStack(spacing: 0) {
            let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
            HStack(spacing: 6) {
                Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill"
                                            : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(filtering ? Color.accentColor : Color.secondary)
                TextField("Filter sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    // ⌃F (via `focusSessionSearch`) jumps focus straight to the filter.
                    .onChange(of: model.sessionSearchFocusToken) { _, _ in searchFocused = true }
                    // Esc clears an active filter (only while the field is focused).
                    .onKeyPress(.escape) {
                        guard filtering else { return .ignored }
                        query = ""
                        return .handled
                    }
                if filtering {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .clickCursor()
                    .help("Clear filter (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(filtering ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(filtering ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: filtering ? 1.5 : 1))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if filtering {
                HStack(spacing: 6) {
                    Text("Showing \(filteredVisibleCount(groups)) of \(unfilteredVisibleCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { query = "" }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .clickCursor()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
            // Custom selection binding rather than a plain `$model.selection`: while
            // the GitHub overlay is up we report no selection, so clicking ANY session
            // row — including the one already selected — is a change the List reports,
            // letting us dismiss the overlay and land on that session. A per-row tap
            // gesture can't do this: attaching one to a native List row swallows the
            // click and breaks selection entirely on macOS. We never write nil back, so
            // the real selection (and its keep-alive pane) survives.
            List(selection: Binding(
                get: { model.showingGitHub ? nil : model.selection },
                set: { newValue in
                    if model.showingGitHub { model.showingGitHub = false }
                    if let newValue { model.selection = newValue }
                }
            )) {
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
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .opacity(dropTarget == group.cwd ? 1 : 0)
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
                            withAnimation(.easeOut(duration: 0.12)) {
                                dropTarget = hovering ? group.cwd : (dropTarget == group.cwd ? nil : dropTarget)
                            }
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
                trackedIssuesSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Slide rows to their new slot when a session dies and sinks, instead
            // of snapping (juancode-05u). Keyed on the per-group ordered id lists so
            // it fires only on an actual reorder, not on every activity tick.
            .animation(.easeInOut(duration: 0.28), value: groups.map { $0.sessions.map(\.id) })
            .focused($listFocused)
            // ⌃H asks the list to take focus; j/k then move the selection (juancode-vgm).
            .onChange(of: model.sidebarFocusToken) { _, _ in listFocused = true }
            // Keep the keyboard monitor's nav order in sync with what's actually shown.
            .onChange(of: visibleIDs) { _, ids in model.navOrder = ids }
            // Minimize projects by default: collapse each folder the first time it
            // appears, then leave the user's manual toggles alone (juancode).
            .onChange(of: groups.map(\.cwd)) { _, cwds in collapseNewFolders(cwds) }
            .onAppear { collapseNewFolders(groups.map(\.cwd)) }
            // Keep the moved selection on-screen (g/G can jump far).
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                // Deferred: a click-driven change arrives via the table's own
                // selection-did-change delegate, and scrolling the same table
                // while that callback is on the stack is a reentrant operation.
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
                }
            }
            }
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
        .onAppear { model.loadExternalSessions(); model.navOrder = visibleIDs }
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
            // Transcript search (magnifier), Kill Port (powerplug) and Auth & MCP
            // status (shield) moved off the sidebar: the filter field above covers
            // in-list finding, and Kill Port + MCP status now live in the top-bar
            // Tools popover (juancode-tciz / juancode-v4ep).
            ToolbarItem {
                Button { model.showingNewSession = true } label: { Image(systemName: "plus") }
                    .help("New session")
                    .clickCursor()
            }
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

    /// A folder's session rows: all of them if ≤ the preview cap; otherwise a preview
    /// with a "Load more" affordance, and once expanded a fixed-height box that scrolls
    /// internally so the sidebar doesn't grow. The preview is sized to fit every active
    /// (live) session — by default live sessions sort ahead of dead ones, though a
    /// manual drag order can hold a dead session in a preview slot.
    @ViewBuilder
    private func sessionList(_ group: FolderGroup) -> some View {
        let sessions = group.sessions
        let previewCount = max(folderPreviewCount, group.running)
        if sessions.count <= previewCount {
            ForEach(sessions, id: \.id) { meta in nativeRow(meta) }
                .onMove { from, to in
                    moveSessions(in: group, shown: sessions, from: from, to: to)
                }
        } else if expandedFolders.contains(group.cwd) {
            scrollBox(group)
        } else {
            let shown = Array(sessions.prefix(previewCount))
            ForEach(shown, id: \.id) { meta in nativeRow(meta) }
                .onMove { from, to in
                    moveSessions(in: group, shown: shown, from: from, to: to)
                }
            Button { withAnimation(.easeOut(duration: 0.18)) { _ = expandedFolders.insert(group.cwd) } } label: {
                Label("Load more (\(sessions.count - previewCount))",
                      systemImage: "chevron.down.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .clickCursor()
        }
    }

    /// All of a folder's sessions inside a height-capped, internally scrolling box.
    /// These rows can't use the List's selection or `.onMove`, so taps set the
    /// selection by hand and reordering is drag-a-row-onto-another, like the
    /// project headers.
    @ViewBuilder
    private func scrollBox(_ group: FolderGroup) -> some View {
        let sessions = group.sessions
        let cwd = group.cwd
        VStack(spacing: 0) {
            ContainedScroll(maxHeight: CGFloat(folderScrollMaxHeight)) {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, meta in
                        // Match the List path's minimal inter-row hairline.
                        if index > 0 {
                            Divider().overlay(Color.appHairline(0.12)).padding(.horizontal, 8)
                        }
                        scrollRow(meta)
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .opacity(sessionDropTarget == meta.id ? 1 : 0)
                            }
                            .draggable(meta.id) {
                                Text(meta.title)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.appSurface.opacity(0.8))
                            }
                            .dropDestination(for: String.self) { items, _ in
                                sessionDropTarget = nil
                                guard let dragged = items.first else { return false }
                                return reorderSessions(in: group, moving: dragged, onto: meta.id)
                            } isTargeted: { hovering in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    sessionDropTarget = hovering
                                        ? meta.id
                                        : (sessionDropTarget == meta.id ? nil : sessionDropTarget)
                                }
                            }
                    }
                }
            }
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
        // Pointing-hand + hover fill for the clickable (selectable) rows; external
        // rows aren't selectable, so they keep the default cursor and no hover fill.
        // The List owns the selection highlight, so we add hover feedback only.
        if external {
            row
        } else {
            row
                .modifier(SelectableRowBackground(selected: model.selection == meta.id,
                                                  drawSelection: false))
                .pointerCursor()
        }
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
            .contentShape(Rectangle())
            .onTapGesture {
                if !external {
                    model.selection = meta.id
                    if model.showingGitHub { model.showingGitHub = false }
                }
            }
            .onAppear { if meta.worktreePath != nil { model.loadFolderGitState(meta.cwd) } }
            .contextMenu { rowContextMenu(meta) }
        // Selection accent + pointing-hand + hover fill for the clickable rows;
        // external rows can't be selected by tap, so they keep the default cursor
        // and no hover feedback.
        if external {
            row
        } else {
            row
                .modifier(SelectableRowBackground(selected: model.selection == meta.id))
                .pointerCursor()
        }
    }

    /// Tracked Linear issues, surfaced in the sidebar (juancode-yluq) — moved off the
    /// top-bar toolbar. Each row jumps to the issue's tracking session; the "+" in the
    /// header opens the full tracking sheet (add / manage). Hidden when nothing tracked.
    @ViewBuilder
    private var trackedIssuesSection: some View {
        let issues = model.trackedIssuesList
        if !issues.isEmpty {
            Section {
                ForEach(issues) { issue in
                    Button {
                        model.selection = issue.sessionId
                        if model.showingGitHub { model.showingGitHub = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "ticket")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(issue.identifier)
                                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                            Text(issue.title).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickCursor()
                    .help(issue.title)
                    .contextMenu {
                        Button("Open in Linear") {
                            if let u = URL(string: issue.url) { NSWorkspace.shared.open(u) }
                        }
                        Button("Untrack \(issue.identifier)") { model.untrackIssue(issue.id) }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Tracked issues").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button { model.showingTrackedIssues = true } label: {
                        Image(systemName: "plus").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .clickCursor()
                    .help("Track a Linear issue / manage tracked issues")
                }
            }
        }
    }

    private func sessionRow(_ meta: SessionMeta) -> SessionRow {
        let external = model.isExternal(meta.id)
        return SessionRow(meta: meta, activity: model.activity(meta.id),
                          live: model.isLive(meta.id), external: external,
                          tracked: external ? nil : model.trackedPr(forSession: meta.id),
                          trackedIssue: external ? nil : model.trackedIssue(forSession: meta.id),
                          unread: model.unreadSessions.contains(meta.id),
                          unseenDone: model.unseenCompletions.contains(meta.id),
                          atRisk: !external && model.workAtRisk(forSession: meta) != nil,
                          worktreeBranch: meta.worktreePath != nil ? model.folderGitState(meta.cwd)?.branch : nil,
                          changeBadge: external ? nil : model.changeBadge(meta.id),
                          onOpenChanges: external ? nil : { model.openChanges(for: meta.id) },
                          onResume: external ? { model.importExternalSession(meta.id) } : nil,
                          onOpenInEditor: (external || meta.kind == .editor)
                              ? nil : { model.openEditorSession(meta.id) },
                          selected: model.selection == meta.id,
                          activating: model.isActivating(meta.id))
    }

    @ViewBuilder
    private func rowContextMenu(_ meta: SessionMeta) -> some View {
        if model.isExternal(meta.id) {
            Button("Resume in juancode") { model.importExternalSession(meta.id) }
        } else {
            Button("Rename…") { beginRename(meta) }
            if meta.kind != .editor {
                Button("Open in Editor") { model.openEditorSession(meta.id) }
            }
            if meta.archived {
                Button("Unarchive") { model.setArchived(meta.id, false) }
            } else {
                Button("Archive") { model.setArchived(meta.id, true) }
            }
            // The log is shared JSONL — grep the session id to follow one row's
            // spawn/seed/activity/exit trail.
            Button("Open Activity Log") { model.revealActivityLog() }
            if let tracked = model.trackedPr(forSession: meta.id) {
                Divider()
                Button("Untrack PR #\(tracked.number)") { model.untrackPr(tracked.id) }
            }
            if let trackedIssue = model.trackedIssue(forSession: meta.id) {
                Divider()
                Button("Untrack issue \(trackedIssue.identifier)") { model.untrackIssue(trackedIssue.id) }
            }
            Divider()
            // Force-terminate a still-running agent without deleting the session,
            // so a stuck/frozen one can be stopped and then inspected (juancode-101).
            // Killed straight from the menu like Delete below: routing it through a
            // @State + .confirmationDialog never presented from a context menu on
            // macOS, so the item read as a no-op (juancode-05u). Kill is
            // non-destructive (session, scrollback and worktree are all kept).
            if model.isLive(meta.id) {
                Button("Kill Agent", role: .destructive) { model.killSession(meta.id) }
            }
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
    @State private var plusHovering = false
    @State private var ghHovering = false

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

    /// Tooltip for the main-checkout uncommitted badge.
    private func mainDirtyHelp(_ r: WorkAtRisk) -> String {
        let branch = r.branch.map { " on \($0)" } ?? ""
        return "Main checkout: \(r.dirtyFiles) uncommitted file(s)\(branch)"
    }

    /// Tooltip for the main-checkout unpushed badge.
    private func mainAheadHelp(_ r: WorkAtRisk) -> String {
        let branch = r.branch.map { " on \($0)" } ?? ""
        return "Main checkout: \(r.ahead) unpushed commit(s)\(r.noUpstream ? " (no upstream)" : "")\(branch)"
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
                        // Per-project worktree default: when on, picking an agent below
                        // starts the session on a fresh git worktree. Persisted per
                        // project, so it sticks for future "+" clicks. Git folders only.
                        if model.folderGitState(group.cwd)?.git == true {
                            Toggle(isOn: Binding(
                                get: { model.worktreeDefault(forProject: group.cwd) },
                                set: { model.setWorktreeDefault($0, forProject: group.cwd) }
                            )) {
                                Text("New worktree")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Start new sessions here on a fresh git worktree")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            Divider().padding(.vertical, 2)
                        }
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
                    .frame(minWidth: 180)
                    .padding(4)
                    .fixesPopoverFirstClick()
                }
                // Per-project GitHub view (juancode-4r4): opens the PR view scoped
                // to this folder, deep-linking to the current branch's PR when
                // there is one. Only for folders with a git remote.
                if model.folderGitState(group.cwd)?.remote == true {
                    Button { model.openGitHubForFolder(group.cwd) } label: {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.appHairline(ghHovering ? 0.14 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help("GitHub PRs for \(group.name) — opens this branch's PR if it has one")
                    .clickCursor()
                    .onHover { ghHovering = $0 }
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
                    // the main checkout's uncommitted and unpushed work get separate
                    // badges (yellow pencil = dirty files, blue arrow.up = unpushed
                    // commits) so the two states read distinctly instead of summing into
                    // one ambiguous number; orange warning = how many distinct WORKTREES
                    // hold at-risk work.
                    if let main = risk.main {
                        if main.dirtyFiles > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 9))
                                Text("\(main.dirtyFiles)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.yellow)
                            .help(mainDirtyHelp(main))
                        }
                        if main.ahead > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 9))
                                Text("\(main.ahead)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.blue)
                            .help(mainAheadHelp(main))
                        }
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
                       role: .destructive) { model.closeSessions(closableSessions.map(\.id)) }
            }
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
                if !showing {
                    model.loadPrs(cwd)
                    // Reopening with a filter still active: re-run the scoped query
                    // since loadPrs resets the cache to the firehose top-50.
                    model.backfillPrs(cwd, mine: mineOnly, assigned: assignedOnly, query: query)
                }
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
        // Instant filtering happens over the cached set above; these fire a
        // debounced, repo-scoped `gh` re-query in the background so matches beyond
        // the newest-50 firehose (e.g. your own older PRs) fold into the view.
        .onChange(of: query) { _, q in
            model.backfillPrs(cwd, mine: mineOnly, assigned: assignedOnly, query: q)
        }
        .onChange(of: mineOnly) { _, m in
            model.backfillPrs(cwd, mine: m, assigned: assignedOnly, query: query)
        }
        .onChange(of: assignedOnly) { _, a in
            model.backfillPrs(cwd, mine: mineOnly, assigned: a, query: query)
        }
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
    /// The agent finished a turn while this session wasn't selected (juancode-t9p) —
    /// shows the green "done since you last looked" check until viewed.
    var unseenDone: Bool = false
    /// This session's folder holds uncommitted/unpushed work (juancode-rxu) — shows
    /// a small warning capsule on the trailing edge.
    var atRisk: Bool = false
    /// Branch this session's worktree is on, when it runs in a juancode-owned git
    /// worktree (`meta.worktreePath != nil`). Drives the branch label + glyph in the
    /// subtitle so worktree rows read distinctly from main-checkout rows. Nil for
    /// non-worktree sessions or until the branch is loaded.
    var worktreeBranch: String? = nil
    /// The agent settled a turn with a dirty tree and the diff changed since it was
    /// last viewed — a compact "N files · +X −Y" review badge. Nil when clean /
    /// already reviewed.
    var changeBadge: ChangeStat? = nil
    /// Opens this session's Changes panel on the working tree (the badge's click target).
    var onOpenChanges: (() -> Void)? = nil
    /// Resume action for an external row; the row is otherwise non-interactive.
    var onResume: (() -> Void)? = nil
    /// Open this session's worktree in $EDITOR — revealed on hover as a pencil on
    /// the trailing edge (moved off the top-bar toolbar, juancode-byc5). Nil for
    /// external/editor rows, which have no editor to open.
    var onOpenInEditor: (() -> Void)? = nil
    /// Whether this row is the current selection — drives showing the external
    /// resume affordance alongside hover.
    var selected: Bool = false
    /// The session's exited pane is being resumed right now (juancode click-to-open
    /// feedback) — swaps the status glyph for a spinner until the pty is back.
    var activating: Bool = false

    @State private var hovering = false

    /// The title renders at 13pt. A firstTextBaseline HStack pins non-text ornaments
    /// to the title's baseline, which sits below the text's optical center — so a bare
    /// dot reads as too low. Shifting each ornament up by half the title's cap height
    /// re-centers it on the title line.
    private nonisolated static let titleCenterShift = NSFont.systemFont(ofSize: 13).capHeight / 2

    var body: some View {
        // firstTextBaseline so the status dot and any trailing ornament sit on the
        // title line — a two-line row (title + usage subtitle) reads as one unit.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIndicator
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.titleCenterShift }
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
                if let changeBadge, let onOpenChanges {
                    changeBadgeCapsule(changeBadge, onOpen: onOpenChanges)
                }
            }
            Spacer(minLength: 6)
            trailingOrnament
        }
        // A sleeping (reaped) row dims as a whole so it reads as resting, not
        // failed — the moon glyph carries the "why".
        .opacity(sleeping ? 0.55 : 1)
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    /// The reaper put this session to sleep and it hasn't been revived yet.
    private var sleeping: Bool { !live && meta.dormant }

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
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.titleCenterShift }
        }
        if external, let onResume, hovering || selected {
            Button(action: onResume) {
                Image(systemName: "play.circle").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("From your terminal — resume in juancode")
            .clickCursor()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.titleCenterShift }
        }
        // Hover-revealed "open in editor" pencil for own sessions (juancode-byc5) —
        // same reveal pattern as the external resume button above. ⌘E does the same
        // for the selected session.
        if !external, let onOpenInEditor, hovering {
            Button(action: onOpenInEditor) {
                Image(systemName: "pencil").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Open this session's worktree in your editor ($EDITOR, ⌘E)")
            .clickCursor()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.titleCenterShift }
        }
    }

    /// The "N files · +X −Y" review badge shown in the subtitle line once the agent
    /// settles a turn with unreviewed changes. A button so a click opens the Changes
    /// panel without also selecting the row.
    private func changeBadgeCapsule(_ stat: ChangeStat, onOpen: @escaping () -> Void) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 3) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 8))
                Text(stat.summary).font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("Changed since you last looked — click to review (⌘⇧C)")
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

    /// Status glyph in the leading slot — the shared agent-state vocabulary.
    private var statusIndicator: some View {
        SessionStateGlyph(live: live, activity: activity, unseenDone: unseenDone,
                          unread: unread, activating: activating, dormant: meta.dormant)
    }
}

/// The agent-state vocabulary (juancode-t9p), one glyph per state so a session
/// list answers "who's working / who needs me / who finished" at a glance:
/// working = pulsing orange dot, waiting = amber question mark, done-unseen =
/// green check (only until the session is viewed), idle/exited = quiet grey dot,
/// sleeping (auto-slept by the reaper) = muted moon.
/// Shared by the sidebar `SessionRow` and the ⌘K jump palette (juancode-dr0) so
/// the two surfaces never drift into different vocabularies.
struct SessionStateGlyph: View {
    let live: Bool
    let activity: SessionActivity?
    let unseenDone: Bool
    var unread: Bool = false
    /// The session is being resumed right now — show a spinner in the glyph slot.
    var activating: Bool = false
    /// The reaper put this session to sleep (`meta.dormant`) — render a moon, not
    /// the exited grey dot, so intentional sleep never reads as a crash.
    var dormant: Bool = false

    private enum Glyph { case working, waiting, doneUnseen, dot, sleeping }

    private var glyph: Glyph {
        guard live else { return dormant ? .sleeping : .dot }
        switch activity {
        case .busy: return .working
        case .waitingInput: return .waiting
        default: return unseenDone ? .doneUnseen : .dot
        }
    }

    /// All variants sit in a fixed-width slot so row titles stay aligned
    /// regardless of which is shown.
    var body: some View {
        Group {
            if activating {
                // Resume in flight — a spinner reads as "opening…" until the pty is back.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .help("Resuming session…")
            } else {
            switch glyph {
            case .working:
                // Pulsing reads as motion without a spinner's churn in a long list.
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
                    .help("Agent is working")
            case .waiting:
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .help("Waiting for your reply")
            case .doneUnseen:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .help("Finished since you last looked — click to view")
            case .sleeping:
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .help("Sleeping — auto-slept after idle. Open it to wake it up.")
            case .dot:
                Circle().fill(sessionDotColor(live: live, activity: activity))
                    .frame(width: 8, height: 8)
            }
            }
        }
        .frame(width: 12, alignment: .center)
        .overlay(alignment: .topTrailing) {
            // The green check already says "unseen", so skip the red dot there.
            if unread, glyph != .doneUnseen {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1))
                    .offset(x: 1, y: -1)
                    .help("Unread — agent finished or needs your reply")
            }
        }
    }
}

/// Status-dot color for a session: busy = orange, waiting = amber, live-but-idle =
/// blue (reads as "running/ready" and stays clearly distinct from the faint grey of
/// an exited session — green is reserved for the done-unseen check, juancode-t9p),
/// exited = dimmer grey. Shared by the sidebar `SessionRow` and the Oracle dock's
/// session rail (juancode-cwa) so the two stay visually in sync.
func sessionDotColor(live: Bool, activity: SessionActivity?) -> Color {
    guard live else { return .secondary.opacity(0.4) }
    switch activity {
    case .busy: return .orange
    case .waitingInput: return .yellow
    case .idle, .none: return .blue
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The GitHub view overlays the session content in a ZStack rather than
        // replacing it: the container underneath must stay MOUNTED so the
        // keep-alive terminal panes survive (juancode-073, juancode-2t6).
        ZStack {
            if let id = model.selection, let meta = model.sessions.first(where: { $0.id == id }) {
                // Deliberately NOT keyed by id: the container must survive session
                // switches so the keep-alive terminal panes inside it stay mounted
                // (juancode-073). Per-session subviews that assume a fresh identity
                // (Changes/Issues panels) are keyed individually inside.
                SessionContainer(meta: meta)
            } else {
                ContentUnavailableView(
                    "No session selected",
                    systemImage: "terminal",
                    description: Text("Pick a session, or create one with +.")
                )
            }
            if model.showingGitHub {
                GitHubView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The views the session's right-side panel can show: the working-tree changes
/// panel (diff + inline comments + git actions), the file-tree sidebar over the
/// session's worktree, or the folder's bd issues.
private enum SidePanelTab: String, CaseIterable {
    case changes = "Changes", files = "Files", issues = "Issues"
}

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
                // Title lives in the window titlebar (.navigationTitle); no need to
                // repeat it here — this row is just the session's action buttons.
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
                .help(panelShown ? "Hide the Changes / Files / Issues panel" : "Show the Changes / Files / Issues panel")
                .clickCursor()
            }
            .padding(8)
            Divider()
            ZStack(alignment: .top) {
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Focus rim flash on teleport landings (juancode-vz1): belongs to
                    // the visible pane container, not the pooled panes inside `terminal`.
                    .overlay { FocusRimFlash(token: model.focusRimFlashToken) }
                    .overlay(alignment: .topTrailing) { remoteDriveBadge }
                    .overlay(alignment: .topLeading) { sessionRestoredBadge }
                    // Review nudge floated at the bottom edge — out of the way of the
                    // top badges + find bar, and an overlay so the pty grid never reflows.
                    .overlay(alignment: .bottom) { changeReviewBanner }
                    // In-pane find bar (⌘F, juancode-972) — overlays the visible
                    // session's pane; never reflows the pty grid.
                    .overlay(alignment: .top) {
                        if model.showingFindBar {
                            TerminalFindBar(sessionId: meta.id)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // Translate the whole session UP by the panel height rather than
                    // resizing the window or squeezing the grid. An `.offset` moves the
                    // layer with a pure transform — no frame change, so no SIGWINCH and
                    // no pty reflow; the newest rows (the prompt) end up right above the
                    // panel and the oldest scroll off the top, exactly like scrolling.
                    // Closing slides it back into place (juancode).
                    .offset(y: model.bottomTerminalShown ? -CGFloat(bottomHeight) : 0)

                // Keep-alive bottom panel, pinned to the bottom edge and slid in from
                // below via a transform. Once this folder has shells the panel stays
                // MOUNTED across toggles at a CONSTANT height — the toggle only moves it,
                // so the shell never reflows either (the height-animating collapse this
                // replaced was the toggle jank, juancode-it1). The `hidden` flag still
                // pauses the shell's rendering while it's off-screen. Never mounts for
                // folders that never opened a terminal.
                if model.bottomTerminalShown || !model.terminalPanel(meta.cwd).isEmpty {
                    VStack(spacing: 0) {
                        // Drag the top edge to resize the panel; previewOnly commits once
                        // on release so the shell reflows in a single clean jump. Just
                        // rewrites `bottomHeight` now — no window resize.
                        DragResizeHandle(axis: .horizontal, value: $bottomHeight,
                                         min: 120, max: 720, previewOnly: true)
                        BottomTerminalPanel(cwd: meta.cwd, hidden: !model.bottomTerminalShown)
                    }
                    .frame(height: CGFloat(bottomHeight))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .offset(y: model.bottomTerminalShown ? 0 : CGFloat(bottomHeight))
                    .allowsHitTesting(model.bottomTerminalShown)
                }
            }
            .clipped()
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
        // Fires once per id change (the container itself is no longer keyed);
        // `openPersistedPane` no-ops if already live, reactivates otherwise, and
        // announces a "restored from disk" banner (juancode-mya) on a session's first
        // revival this run. The pane-pool note backstops the synchronous one in the
        // `selection` setter for opens that reach here by another route.
        .task(id: meta.id) {
            await model.openPersistedPane(meta.id)
            model.noteLivePaneVisible(meta.id)
        }
        // The live Session OBJECT behind the selected id can change while we're
        // showing it — a reactivation or a permissions flip mints a new one. The
        // pool keys panes by object identity, so re-note to mount the new pty's
        // pane (the stale entry is pruned by `AppModel.refresh`).
        .onChange(of: model.liveSession(meta.id).map(ObjectIdentifier.init)) { _, _ in
            model.noteLivePaneVisible(meta.id)
        }
    }

    /// The right-side panel: a Changes | Files | Issues tab switcher hosting the
    /// self-contained `ChangesPanel` (session diff), `FileTreePanel` (worktree
    /// explorer), and `IssuesPanel` (folder bd issues). The active tab is
    /// remembered app-wide via @AppStorage.
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
            // Keyed explicitly: the container is no longer recreated per session
            // (keep-alive terminal pool, juancode-073), but these panels hold
            // per-session/per-folder @State seeded in onAppear.
            switch tab {
            case .changes: ChangesPanel(sessionId: meta.id).id(meta.id)
            case .files: FileTreePanel(sessionId: meta.id, root: meta.effectiveCwd).id(meta.id)
            case .issues: IssuesPanel(cwd: meta.cwd).id(meta.cwd)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Remote is driving" overlay (juancode-2t4): while a web/phone viewer owns
    /// this session's pty grid, badge the visible pane and offer a one-click
    /// take-back. Take-back is the existing geometry resync — its forced local
    /// SIGWINCH preempts the remote owner by policy (juancode-1th.1) and the
    /// resulting grid change dismisses the badge through `remoteGridOwner`.
    /// Keyed by owner so a different viewer taking over restarts the overlay's
    /// collapse timer. Hidden pool panes deliberately released their grid
    /// (juancode-073) — they're off-screen, so only the visible pane is badged.
    @ViewBuilder
    private var remoteDriveBadge: some View {
        if model.isLive(meta.id), let owner = model.remoteGridOwner(meta.id) {
            RemoteDriveOverlay(owner: owner) { model.resyncTerminalGeometry() }
                .id(owner)
                .padding(10)
        }
    }

    /// "Restored from disk" banner (juancode-mya): shown top-leading over a pane a
    /// cold launch replayed from persisted scrollback, so a frozen-looking wall of
    /// old output is self-explaining. Keyed by session id so switching panes shows
    /// the new one's banner (or none). Stacks beside the top-trailing remote-drive
    /// badge instead of overlapping it.
    @ViewBuilder
    private var sessionRestoredBadge: some View {
        if let phase = model.restoredBannerPhase(meta.id) {
            SessionRestoredOverlay(phase: phase) { model.dismissRestoredBanner(meta.id) }
                .id(meta.id)
                .padding(10)
        }
    }

    /// Review nudge over the terminal once the agent settles a turn with unreviewed
    /// changes; clears when its Changes panel is opened (see `AppModel.changeBadge`).
    @ViewBuilder
    private var changeReviewBanner: some View {
        if let stat = model.changeBadge(meta.id) {
            ChangeReviewBanner(summary: stat.summary) { model.openChanges(for: meta.id) }
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var terminal: some View {
        // Keep-alive pane pool (juancode-073): every recently-viewed live session
        // keeps its Ghostty surface MOUNTED here, hidden panes with rendering
        // suspended and pty sizing frozen (`GhosttyLive.hidden`). Switching
        // sessions just flips which pane is visible — no teardown, so returning
        // never replays raw scrollback (the replay-garble bug class). Pool
        // membership/eviction lives in `AppModel.livePanes`; each pane's identity
        // is its Session object + the refresh token it mounted with, so the
        // Refresh CTA (token bump on the visible entry) and a permissions flip
        // (new Session object) still fully recreate that one pane.
        if TerminalBackendChoice.useGhostty {
            let current = model.liveSession(meta.id)
            ZStack {
                ForEach(model.livePanes.entries) { entry in
                    let visible = entry.session === current
                    GhosttyLive(session: entry.session,
                                focusToken: model.terminalFocusToken,
                                resyncToken: model.terminalResyncToken,
                                autoFocusOnAppear: !model.suppressTerminalAutoFocus,
                                hidden: !visible)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                }
                if current == nil {
                    SwiftTermReplay(scrollback: model.scrollback(meta.id))
                }
            }
        } else if let session = model.liveSession(meta.id) {
            // SwiftTerm fallback (JUANCODE_SWIFTTERM=1): no keep-alive pool —
            // the old behavior, one live pane keyed by Session object identity
            // (permissions flip) + refresh token (Refresh CTA), teardown+replay
            // on every switch.
            SwiftTermLive(session: session,
                          focusToken: model.terminalFocusToken,
                          resyncToken: model.terminalResyncToken,
                          autoFocusOnAppear: !model.suppressTerminalAutoFocus,
                          onOpenPath: { path, line in model.openEditorSession(meta.id, file: path, line: line) })
                .id(TerminalIdentity(session: session, refresh: model.terminalRefreshToken))
        } else {
            SwiftTermReplay(scrollback: model.scrollback(meta.id))
        }
    }
}

/// An accent rim that flashes on a teleport landing (juancode-vz1). Each `token`
/// bump snaps the rim to full opacity with animations disabled, then fades it out
/// over ~1.5s — the SwiftUI equivalent of orca's remove-class + forced-reflow +
/// re-add, so a bump mid-fade restarts cleanly from full instead of continuing the
/// in-flight fade. Purely decorative: never hit-tests, so clicks fall through to
/// the terminal beneath.
private struct FocusRimFlash: View {
    let token: Int
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 6)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: token) { _, _ in
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { opacity = 1 }
                withAnimation(.easeOut(duration: 1.5)) { opacity = 0 }
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
    // Opening prompt, auto-submitted once the CLI is ready (Session.autoSubmit).
    @State private var prompt = ""
    // Fan-out: how many parallel agents (each its own worktree) to spawn with the
    // same prompt. Only meaningful when `isolateWorktree` is on; >1 requires it.
    @State private var agentCount = 1
    @State private var creating = false
    @State private var showingDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2).bold()
            VStack(alignment: .leading, spacing: 4) {
                Text("Opening prompt").font(.system(size: 13, weight: .semibold))
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 64)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                Text("Submitted once the CLI is ready. Leave blank to start idle.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
                // Fan-out only appears once worktree isolation is on — >1 agent on a
                // shared checkout would collide. Toggling worktree off resets to 1.
                if isolateWorktree {
                    Stepper(value: $agentCount, in: 1...FanOut.maxAgents) {
                        Text(agentCount == 1
                             ? "Run 1 agent"
                             : "Fan out to \(agentCount) agents (compare results)")
                    }
                }
            }
            .onChange(of: isolateWorktree) { _, on in if !on { agentCount = 1 } }
            continueExisting
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button(startLabel) { start() }
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

    private var startLabel: String {
        if creating { return "Starting…" }
        return (isolateWorktree && agentCount > 1) ? "Start \(agentCount) agents" : "Start"
    }

    private func start() {
        creating = true
        let seed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialInput = seed.isEmpty ? nil : seed
        Task {
            let started: Bool
            if isolateWorktree, agentCount > 1 {
                let sessions = await model.createFanOut(
                    provider: provider, cwd: cwd, skipPermissions: skipPermissions,
                    count: agentCount, initialInput: initialInput)
                started = !sessions.isEmpty
            } else {
                let session = await model.create(
                    provider: provider, cwd: cwd, skipPermissions: skipPermissions,
                    isolateWorktree: isolateWorktree, initialInput: initialInput, select: true)
                started = session != nil
            }
            creating = false
            if started { dismiss() }
        }
    }
}
