import SwiftUI
import JuancodeCore
import JuancodeServices

/// The global "Oracle" helper (juancode-wjg / juancode-6sw): a right-docked,
/// full-height side panel with two tabs — a global bd issue view (dispatch into a
/// project / ask Oracle) and the Oracle agent's live chat terminal. Opened from the
/// top command bar or ⌃Space; it slides in over the right edge with a minimum width
/// so the agent CLI always boots into a usable, stable grid (a fixed drawer avoids
/// the live-reflow fragility of a free-floating resizable panel).
struct OracleDock: View {
    @Environment(OracleModel.self) private var oracle
    /// Persisted panel width (drag the left edge). Floored so the agent CLI never
    /// renders into too few columns (which garbles its TUI).
    @AppStorage("oracle.panel.width") private var panelWidth: Double = 600
    /// Whether the chat tab's mini session rail (juancode-cwa) is shown. Shared with
    /// `OracleChatView` via the same @AppStorage key so the header toggle and the rail
    /// stay in lock-step.
    @AppStorage("oracle.sessionRail.shown") private var sessionRailShown = true
    private static let minWidth: Double = 460
    private static let maxWidth: Double = 1100

    var body: some View {
        ZStack(alignment: .trailing) {
            if oracle.expanded {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { oracle.collapse() }
                    .transition(.opacity)
            }
            // The panel stays mounted across toggles and slides off the right edge when
            // collapsed, rather than being inserted/removed. Tearing it down rebuilt the
            // terminal surface and replayed scrollback on every open — a visible flicker.
            // Sliding keeps the live grid intact, so reopening is instant and clean.
            panel
                .offset(x: oracle.expanded ? 0 : hiddenOffset)
                .allowsHitTesting(oracle.expanded)
        }
        // Always fill the window AND pin the content to the trailing edge. When
        // collapsed there's no full-width scrim, so the ZStack shrinks to the
        // panel's own width; a plain fill frame would center that narrow box,
        // leaving the panel ~half the window from the right edge and `hiddenOffset`
        // only sliding it partway off (a visible strip stays). Aligning to
        // `.trailing` keeps the panel flush against the real right edge in both
        // states, so the slide-off-screen geometry is correct.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.16), value: oracle.expanded)
        .onAppear { oracle.bootstrap() }
    }

    /// How far to push the collapsed panel past the right edge so nothing (incl. its
    /// shadow + drag handle) peeks back in.
    private var hiddenOffset: Double {
        min(Self.maxWidth, max(Self.minWidth, panelWidth)) + 60
    }

    private var panel: some View {
        @Bindable var oracle = oracle
        let w = min(Self.maxWidth, max(Self.minWidth, panelWidth))
        return HStack(spacing: 0) {
            // Drag the left edge to widen/narrow the drawer (drag left grows it). A
            // preview-only drag: the CLI's full-screen TUI garbles if it repaints at
            // every intermediate width, so we show a guide line and commit the new
            // width once on release — a single clean reflow.
            DragResizeHandle(axis: .vertical, value: $panelWidth,
                             min: Self.minWidth, max: Self.maxWidth, invert: true,
                             previewOnly: true)
            VStack(spacing: 0) {
                header
                Divider()
                Picker("", selection: $oracle.tab) {
                    ForEach(OracleModel.OracleTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: w)
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.07))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
        }
        .shadow(radius: 24, x: -6)
        // Esc closes it (the close button mirrors this). Only while expanded — the
        // panel is always mounted now, and an always-live cancelAction would swallow
        // Esc app-wide even when the dock is closed.
        .background {
            if oracle.expanded {
                Button("") { oracle.collapse() }
                    .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    /// One header toolbar: title on the left, then the tab's contextual action(s) and
    /// the close button on the right — all the same borderless icon-button styling at a
    /// single level (juancode-cwa). Previously the issues Refresh sat buried in the
    /// content row while restart/close lived up here, so the controls read as
    /// misaligned; routing every action through `headerButton` keeps them consistent.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint).padding(.leading, 12)
            Text("Oracle").font(.system(size: 13, weight: .semibold))
            Spacer()
            switch oracle.tab {
            case .issues:
                headerButton("arrow.clockwise", help: "Refresh issues") { oracle.loadGlobalBeads() }
            case .chat:
                headerButton(sessionRailShown ? "sidebar.left" : "sidebar.squares.left",
                             help: sessionRailShown ? "Hide the session list" : "Show the session list") {
                    sessionRailShown.toggle()
                }
                if oracle.session != nil {
                    headerButton("arrow.clockwise", help: "Restart the Oracle agent") { oracle.restartAgent() }
                }
            }
            headerButton("chevron.right", help: "Close (⌃Space)") { oracle.collapse() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// A header action: a borderless icon button with a tooltip and the click cursor,
    /// so every control in the header shares one look.
    private func headerButton(_ icon: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.borderless)
            .help(help)
            .clickCursor()
    }

    @ViewBuilder private var content: some View {
        if let err = oracle.setupError {
            centered("Oracle unavailable:\n\(err)")
        } else if !oracle.ready {
            centered("Setting up Oracle…")
        } else {
            switch oracle.tab {
            case .issues: OracleIssuesView()
            case .chat: OracleChatView()
            }
        }
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The global bd tracker, grouped by actionability via `BeadsGrouping`. Each open
/// item offers Dispatch… (spawn an agent in a project) and Ask Oracle (hand the
/// item to the agent to reason about).
private struct OracleIssuesView: View {
    @Environment(OracleModel.self) private var oracle
    @State private var query = ""

    private var result: BeadsResult? { oracle.globalBeads }

    private var groups: [BeadsGroup] {
        guard let r = result, r.available else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? r.issues
            : r.issues.filter { "\($0.id) \($0.title)".lowercased().contains(q) }
        return BeadsGrouping.grouped(filtered, includeClosed: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Refresh now lives in the dock header alongside the other controls
            // (juancode-cwa); this row is just the filter field.
            TextField("Filter global items…", text: $query)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if result == nil {
            centered("Loading…")
        } else if let r = result, !r.available {
            centered(r.error ?? "No global tracker yet")
        } else if groups.isEmpty {
            centered(query.isEmpty ? "No global items yet.\nAsk Oracle to capture one." : "No matching items")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.section) { group in
                        HStack {
                            Text(group.section.title.uppercased())
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text("\(group.issues.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(group.issues, id: \.id) { issue in
                            OracleIssueRow(issue: issue)
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One global item: status dot, id/priority, title, and the dispatch / ask actions.
private struct OracleIssueRow: View {
    @Environment(OracleModel.self) private var oracle
    let issue: BeadsIssue
    @State private var showingDispatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(statusLabel)
                Text("p\(issue.priority)").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Text(issue.id).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if issue.blocked {
                    Text("blocked").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            Text(issue.title).font(.system(size: 12)).lineLimit(2).help(issue.title)
            if !issue.isClosed {
                HStack(spacing: 12) {
                    Button("Dispatch…") { showingDispatch = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .help("Spawn an agent in a project, seeded with this item")
                        .popover(isPresented: $showingDispatch, arrowEdge: .bottom) {
                            OracleDispatchPicker(issue: issue) { showingDispatch = false }
                        }
                        .clickCursor()
                    Button("Ask Oracle") {
                        oracle.ask(issuePrompt(id: issue.id, title: issue.title))
                    }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Hand this item to the Oracle agent to reason about / orchestrate")
                    .clickCursor()
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var statusColor: Color {
        if issue.isClosed { return .secondary }
        if issue.blocked { return .orange }
        if issue.ready { return .green }
        return .blue
    }
    private var statusLabel: String {
        if issue.isClosed { return "Closed" }
        if issue.blocked { return "Blocked" }
        if issue.ready { return "Ready" }
        return issue.status
    }
}

/// Pick the target project + provider + worktree for dispatching a global item.
/// Project choices are the work dirs already in play, plus a free-text path.
private struct OracleDispatchPicker: View {
    @Environment(OracleModel.self) private var oracle
    let issue: BeadsIssue
    let dismiss: () -> Void

    @State private var project = ""
    @State private var provider: ProviderId = .claude
    @State private var worktree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dispatch \(issue.id)").font(.system(size: 12, weight: .semibold))
            if !oracle.knownProjects.isEmpty {
                Picker("Project", selection: $project) {
                    Text("Choose a project…").tag("")
                    ForEach(oracle.knownProjects, id: \.self) { p in
                        Text((p as NSString).lastPathComponent).tag(p)
                    }
                }
                .font(.system(size: 11))
            }
            TextField("Project path", text: $project)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Picker("Agent", selection: $provider) {
                ForEach(ProviderId.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle("Isolate in a fresh git worktree", isOn: $worktree)
                .toggleStyle(.checkbox).font(.system(size: 11))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.controlSize(.small).clickCursor()
                Button("Dispatch") {
                    oracle.dispatch(
                        project: project.trimmingCharacters(in: .whitespaces),
                        prompt: issuePrompt(id: issue.id, title: issue.title),
                        provider: provider, worktree: worktree)
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(project.trimmingCharacters(in: .whitespaces).isEmpty)
                .clickCursor()
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// The Oracle agent's live chat terminal, with an optional mini session rail on the
/// left (juancode-cwa) so all your work is navigable at a glance without leaving the
/// dock, or a starting affordance when the agent isn't up.
private struct OracleChatView: View {
    @Environment(OracleModel.self) private var oracle
    @AppStorage("oracle.sessionRail.shown") private var sessionRailShown = true

    var body: some View {
        HStack(spacing: 0) {
            if sessionRailShown {
                OracleSessionRail()
                    .frame(width: 156)
                Divider()
            }
            terminal
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var terminal: some View {
        if let session = oracle.session {
            // Same pattern as the main session pane (which resizes correctly): a
            // plain fill. `sizeThatFits` makes the bridged view take the proposed size.
            // GhosttyKit by default; JUANCODE_SWIFTTERM=1 falls back to SwiftTerm.
            // The resizable dock is the key glitch test case.
            Group {
                if TerminalBackendChoice.useGhostty {
                    GhosttyLive(session: session, remembersSize: false,
                                focusToken: oracle.chatFocusToken,
                                onGrid: { cols, rows in oracle.rememberDockGrid(cols: cols, rows: rows) })
                        .id(ObjectIdentifier(session))
                } else {
                    SwiftTermLive(session: session, remembersSize: false, focusToken: oracle.chatFocusToken)
                        .id(ObjectIdentifier(session))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Oracle agent isn't running.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Start Oracle") { oracle.startAgent() }.controlSize(.small).clickCursor()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A compact rail listing all your project sessions (the Oracle agent's own control-dir
/// session is hidden — its terminal is right there). Each row shows a live-status dot,
/// title, and folder; tapping selects it in the main window and collapses the dock so
/// you land straight on it (juancode-cwa). Oracle's dock thus doubles as mission control.
private struct OracleSessionRail: View {
    @Environment(AppModel.self) private var model
    @Environment(OracleModel.self) private var oracle

    /// Own (non-external) sessions, minus the Oracle control dir and archived ones,
    /// most-recent first so freshly dispatched work surfaces at the top.
    private var sessions: [SessionMeta] {
        model.sessions
            .filter { $0.cwd != OraclePaths.controlDir && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Sessions")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(sessions.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            Divider()
            if sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No sessions yet")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions, id: \.id) { meta in row(meta) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.10))
    }

    private func row(_ meta: SessionMeta) -> some View {
        let selected = model.selection == meta.id
        return HStack(spacing: 6) {
            Circle()
                .fill(sessionDotColor(live: model.isLive(meta.id), activity: model.activity(meta.id)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title).font(.system(size: 11)).lineLimit(1)
                Text((meta.cwd as NSString).lastPathComponent)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = meta.id
            oracle.collapse()
        }
        .help(meta.cwd)
        .clickCursor()
    }
}
