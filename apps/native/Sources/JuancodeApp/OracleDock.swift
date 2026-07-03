import SwiftUI
import JuancodeCore
import JuancodeServices

/// The global "Oracle" helper (juancode-wjg / juancode-6sw): a right-docked,
/// full-height side panel. Chat is the whole surface — the Oracle agent's live
/// terminal plus the session rail; the global bd issue view (dispatch into a
/// project / ask Oracle) is reached via a header button rather than a tab bar.
/// Opened from the top command bar or ⌃Space; it slides in over the right edge
/// with a minimum width so the agent CLI always boots into a usable, stable grid
/// (a fixed drawer avoids the live-reflow fragility of a free-floating panel).
struct OracleDock: View {
    @Environment(OracleModel.self) private var oracle
    @Environment(AppModel.self) private var model
    /// Panel width (drag the left edge), persisted once the user drags it. Nil =
    /// never resized → the screen-size-proportional default applies (juancode-it1).
    /// Floored so the agent CLI never renders into too few columns (which garbles
    /// its TUI).
    @AppStorage("oracle.panel.width") private var storedPanelWidth: Double?
    /// Whether the chat tab's mini session rail (juancode-cwa) is shown. Shared with
    /// `OracleChatView` via the same @AppStorage key so the header toggle and the rail
    /// stay in lock-step.
    @AppStorage("oracle.sessionRail.shown") private var sessionRailShown = true
    private static let minWidth: Double = 460

    /// Effective width: the user's persisted width if they ever dragged the edge,
    /// else ~38% of the window (capped — the cap bounds the auto default only).
    private var panelWidth: Double {
        storedPanelWidth ?? PanelAutoSize.width(window: model.windowWidth,
                                                fraction: 0.38, min: 600, max: 900)
    }

    /// Manual-drag ceiling: scales with the window (70%, up to 1400) but never
    /// below the historical 1100 so existing wide setups don't get clamped down.
    private var maxWidth: Double {
        max(1100, min(Double(model.windowWidth) * 0.7, 1400))
    }

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
        // Gate the WHOLE overlay's hit testing on `expanded`. This overlay covers the
        // entire window (RootView), so any hittable shape inside it (the scrim, or a
        // scrim still fading out under the removal transition) would swallow every
        // click meant for the app behind it. The scrim's `.transition(.opacity)` keeps
        // it briefly mounted after collapse, and SwiftUI can leave that fading view
        // intercepting hits until the next render — which is why clicks only came back
        // after reopening the dock. Flipping the entire overlay click-through the
        // instant it collapses makes the underlying app immediately clickable again.
        .allowsHitTesting(oracle.expanded)
        .animation(.easeOut(duration: 0.16), value: oracle.expanded)
        // Open the app into the Oracle chat (juancode-8n0): chat is the main surface,
        // so the dock auto-presents on the chat tab at first launch. A one-shot inside
        // `presentChatAtLaunch`, so it won't re-open after the user closes it.
        .onAppear { oracle.presentChatAtLaunch() }
    }

    /// How far to push the collapsed panel past the right edge so nothing (incl. its
    /// shadow + drag handle) peeks back in.
    private var hiddenOffset: Double {
        min(maxWidth, max(Self.minWidth, panelWidth)) + 60
    }

    private var panel: some View {
        let w = min(maxWidth, max(Self.minWidth, panelWidth))
        return HStack(spacing: 0) {
            // Drag the left edge to widen/narrow the drawer (drag left grows it). A
            // preview-only drag: the CLI's full-screen TUI garbles if it repaints at
            // every intermediate width, so we show a guide line and commit the new
            // width once on release — a single clean reflow. Writing through the
            // binding persists the width — manual wins over the auto default.
            DragResizeHandle(axis: .vertical,
                             value: Binding(get: { panelWidth },
                                            set: { storedPanelWidth = $0 }),
                             min: Self.minWidth, max: maxWidth, invert: true,
                             previewOnly: true)
            VStack(spacing: 0) {
                header
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: w)
        }
        .frame(maxHeight: .infinity)
        .background(Color.appPanel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.appHairline(0.12)).frame(width: 1)
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
                headerButton("sparkles", help: "Back to chat") {
                    oracle.tab = .chat
                    oracle.chatFocusToken += 1
                }
            case .chat:
                // Issues is a header action, not a tab (juancode dock cleanup): chat
                // owns the panel; this flips the content to the global bd view.
                headerButton("tray.full", help: "Global issues") {
                    oracle.tab = .issues
                    oracle.loadGlobalBeads()
                }
                headerButton(sessionRailShown ? "sidebar.left" : "sidebar.squares.left",
                             help: sessionRailShown ? "Hide the session list" : "Show the session list") {
                    sessionRailShown.toggle()
                }
                if oracle.session != nil {
                    headerButton("arrow.clockwise", help: "Refresh terminal — rebuild and replay scrollback to fix a corrupted render") { oracle.refreshChat() }
                    headerButton("arrow.triangle.2.circlepath", help: "Restart the Oracle agent") { oracle.restartAgent() }
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
                    .frame(width: 220)
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
                // `.id` folds in `chatRefreshToken`: the Refresh button bumps it,
                // recreating the view so it replays scrollback and repaints clean.
                if TerminalBackendChoice.useGhostty {
                    GhosttyLive(session: session, remembersSize: false,
                                focusToken: oracle.chatFocusToken,
                                onGrid: { cols, rows in oracle.rememberDockGrid(cols: cols, rows: rows) })
                        .id(TerminalIdentity(session: session, refresh: oracle.chatRefreshToken))
                } else {
                    SwiftTermLive(session: session, remembersSize: false, focusToken: oracle.chatFocusToken)
                        .id(TerminalIdentity(session: session, refresh: oracle.chatRefreshToken))
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

/// A compact rail listing the running Oracle agents (you can spin up several in
/// parallel; they all live in the control dir). Each row shows a live-status dot and
/// title; tapping switches the chat to that Oracle, and the "+" starts a new one
/// (juancode-cwa). Only Oracle sessions appear here — never project/dispatched work.
private struct OracleSessionRail: View {
    @Environment(AppModel.self) private var model
    @Environment(OracleModel.self) private var oracle

    /// The running Oracles, most-recent first (see `OracleModel.oracleSessions`).
    private var sessions: [SessionMeta] { oracle.oracleSessions }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Oracles")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(sessions.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { oracle.newOracle() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Start another Oracle")
                    .clickCursor()
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            Divider()
            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No Oracle running.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Start Oracle") { oracle.newOracle() }
                        .controlSize(.small).clickCursor()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, meta in
                            row(meta, number: sessions.count - idx)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.appPanelElevated)
    }

    /// A session row leads with its auto-derived title — the CLI's own model-written
    /// conversation title, picked up by the title poll (SessionTitle.swift) — so the
    /// rail reads as a list of conversations, not anonymous "Oracle N" slots. Until
    /// the CLI writes one the title is still the spawn placeholder ("<agent> · <dir>",
    /// identical for every Oracle since they share the control dir), so we fall back
    /// to the spawn-order number (oldest = 1) to keep rows distinct.
    private func row(_ meta: SessionMeta, number: Int) -> some View {
        let selected = oracle.oracleSessionId == meta.id
        let placeholder = meta.title.hasPrefix(Providers.spec(for: meta.provider).label + " ·")
        return HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(sessionDotColor(live: model.isLive(meta.id), activity: model.activity(meta.id)))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(placeholder ? "Oracle \(number)" : meta.title)
                    .font(.system(size: 12)).lineLimit(2)
                if !placeholder {
                    Text("Oracle \(number)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { oracle.selectOracle(meta.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { oracle.deleteOracle(meta.id) }
        }
        .help(meta.title)
        .clickCursor()
    }
}
