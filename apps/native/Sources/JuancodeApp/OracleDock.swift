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
    private static let minWidth: Double = 460
    private static let maxWidth: Double = 1100

    var body: some View {
        ZStack(alignment: .trailing) {
            if oracle.expanded {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { oracle.expanded = false }
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
                Button("") { oracle.expanded = false }
                    .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint).padding(.leading, 12)
            Text("Oracle").font(.system(size: 13, weight: .semibold))
            Spacer()
            if oracle.tab == .chat, oracle.session != nil {
                Button { oracle.restartAgent() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Restart the Oracle agent")
                    .clickCursor()
            }
            Button { oracle.expanded = false } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Close (⌃Space)")
                .clickCursor()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
            HStack(spacing: 6) {
                TextField("Filter global items…", text: $query)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button { oracle.loadGlobalBeads() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless).help("Refresh")
                .clickCursor()
            }
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

/// The Oracle agent's live chat terminal, or a starting affordance.
private struct OracleChatView: View {
    @Environment(OracleModel.self) private var oracle

    var body: some View {
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
