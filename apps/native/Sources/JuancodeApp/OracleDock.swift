import SwiftUI
import JuancodeCore
import JuancodeServices

/// The global "Oracle" helper docked at the bottom-right (juancode-wjg). Collapsed
/// it's a floating pill with the open-item count; expanded it's a panel with two
/// tabs — a global bd issue view (dispatch into a project / ask Oracle) and the
/// Oracle agent's live chat terminal. It overlays the whole window, independent of
/// which session/workdir is focused.
struct OracleDock: View {
    @EnvironmentObject var oracle: OracleModel
    /// Persisted dock size. Defaults wide enough that the agent's full-screen TUI
    /// gets ~80 columns and renders cleanly (a narrow dock makes claude/codex draw
    /// 80-col lines into too few columns → overlapping garbage). Resizable via the
    /// top-left grip.
    @AppStorage("oracle.dock.width") private var dockWidth: Double = 680
    @AppStorage("oracle.dock.height") private var dockHeight: Double = 620

    var body: some View {
        Group {
            if oracle.expanded {
                panel
            } else {
                collapsedButton
            }
        }
        .padding(16)
        .onAppear { oracle.bootstrap() }
    }

    private var collapsedButton: some View {
        Button { oracle.expanded = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Oracle").font(.system(size: 12, weight: .medium))
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.22))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .shadow(radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Open Oracle — global tracker + orchestration")
    }

    private var panel: some View {
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
            content
        }
        .frame(width: dockWidth, height: dockHeight)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        // Drag the top-left corner to resize (the dock is pinned bottom-right, so
        // growing reaches up and to the left).
        .overlay(alignment: .topLeading) { resizeGrip }
        .shadow(radius: 16, y: 4)
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(5)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        dockWidth = min(1200, max(420, dockWidth - v.translation.width))
                        dockHeight = min(1000, max(320, dockHeight - v.translation.height))
                    })
            .help("Drag to resize")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Oracle").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { oracle.expanded = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .help("Collapse")
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

    private var openCount: Int {
        guard let r = oracle.globalBeads, r.available else { return 0 }
        return r.issues.filter { $0.status != "closed" }.count
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
    @EnvironmentObject var oracle: OracleModel
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
    @EnvironmentObject var oracle: OracleModel
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
                    Button("Ask Oracle") {
                        oracle.ask(issuePrompt(id: issue.id, title: issue.title))
                    }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Hand this item to the Oracle agent to reason about / orchestrate")
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
    @EnvironmentObject var oracle: OracleModel
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
                Button("Cancel") { dismiss() }.controlSize(.small)
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
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// The Oracle agent's live chat terminal, or a starting affordance.
private struct OracleChatView: View {
    @EnvironmentObject var oracle: OracleModel

    var body: some View {
        if let session = oracle.session {
            SwiftTermLive(session: session)
                .id(ObjectIdentifier(session))
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Oracle agent isn't running.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Start Oracle") { oracle.bootstrap() }.controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
