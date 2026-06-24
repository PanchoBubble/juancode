import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JuancodeCore
import JuancodeServices

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
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

/// A folder's sessions, mirroring the web `FolderGroup` (groupByFolder).
private struct FolderGroup: Identifiable {
    let cwd: String
    /// Last path segment of the cwd, shown as the header label.
    let name: String
    let sessions: [SessionMeta]
    let running: Int
    var id: String { cwd }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    /// Free-text filter over folder names/paths + session titles.
    @State private var query = ""

    /// Sessions filtered by `query` (case-insensitive over title + cwd), then
    /// grouped by folder and sorted stably by cwd — mirrors the web sidebar.
    private var groups: [FolderGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty
            ? model.sessions
            : model.sessions.filter {
                $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
            }
        let byCwd = Dictionary(grouping: filtered, by: \.cwd)
        return byCwd.map { cwd, sessions in
            FolderGroup(
                cwd: cwd,
                name: (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent,
                sessions: sessions,
                running: sessions.filter { model.isLive($0.id) }.count)
        }
        .sorted { $0.cwd.localizedCompare($1.cwd) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter sessions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            List(selection: $model.selection) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions, id: \.id) { meta in
                            SessionRow(meta: meta, activity: model.activity(meta.id), live: model.isLive(meta.id))
                                .tag(meta.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) { model.delete(meta.id) }
                                }
                        }
                    } header: {
                        FolderHeader(group: group)
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No sessions yet." : "No matching sessions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .toolbar {
            ToolbarItem {
                Button { model.showingNewSession = true } label: { Image(systemName: "plus") }
                    .help("New session")
            }
        }
        .navigationTitle("juancode")
    }
}

/// Collapsible section header for a folder: name (full path as tooltip), a
/// running-session badge, and a per-folder "+" agent menu that spawns a new
/// session in this folder. Mirrors the web sidebar's folder `<summary>`.
private struct FolderHeader: View {
    @EnvironmentObject var model: AppModel
    let group: FolderGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.name).lineLimit(1).help(group.cwd)
            if group.running > 0 {
                Text("\(group.running) running")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
            Spacer()
            Menu {
                ForEach(ProviderId.allCases, id: \.self) { p in
                    Button(Providers.spec(for: p).label) {
                        model.createInFolder(provider: p, cwd: group.cwd)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New session in \(group.cwd)")
            FolderIssues(cwd: group.cwd)
            FolderPrs(cwd: group.cwd)
        }
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
    @EnvironmentObject var model: AppModel
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
                    Toggle("Assigned (\(assignedCount))", isOn: $assignedOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
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
    @EnvironmentObject var model: AppModel
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
                Button("Work on") {
                    dismiss()
                    model.workOnPr(pr, cwd: cwd)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                // Track (juancode-it5): hand the PR to a dedicated agent session that
                // watches for new review comments / CI status and auto-fixes the
                // obvious ones, escalating real decisions back here.
                if let t = tracked {
                    TrackBadge(state: t.state)
                    Button("Untrack") { model.untrackPr(t.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Stop watching this PR (keeps the session)")
                } else {
                    Button("Track") { model.trackPr(pr, cwd: cwd) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Watch this PR — auto-fix review comments & CI, escalate decisions")
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
                            Button("Dismiss") {
                                model.resolveNotification(prId: t.id, notificationId: note.id)
                            }
                            .buttonStyle(.borderless).font(.system(size: 9))
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
private struct TrackBadge: View {
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
    @EnvironmentObject var model: AppModel
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
    @EnvironmentObject var model: AppModel
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

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title).lineLimit(1).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if meta.skipPermissions {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Accept all (skip permission prompts) is on")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let folder = (meta.cwd as NSString).lastPathComponent
        if let u = meta.usage, u.totalTokens > 0 {
            return "\(folder) · \(u.totalTokens) tok"
        }
        return folder
    }

    private var dotColor: Color {
        guard live else { return .secondary.opacity(0.4) }
        switch activity {
        case .busy: return .orange
        case .waitingInput: return .blue
        case .idle, .none: return .green
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel

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

struct SessionContainer: View {
    @EnvironmentObject var model: AppModel
    let meta: SessionMeta

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                if model.isLive(meta.id) {
                    acceptAllToggle
                    Label("live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button("Reactivate") { Task { await model.reactivate(meta.id) } }
                        .controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            terminal
        }
        .navigationTitle(meta.title)
    }

    /// Per-session accept-all switch. Flipping it resume-restarts the CLI at the
    /// new permission level (conversation + scrollback preserved). Disabled while
    /// the flip is in flight.
    private var acceptAllToggle: some View {
        let flipping = model.flippingPermissions.contains(meta.id)
        return Toggle("Accept all", isOn: Binding(
            get: { meta.skipPermissions },
            set: { skip in Task { await model.setSkipPermissions(meta.id, to: skip) } }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.caption)
        .disabled(flipping)
        .help("Skip permission prompts for this session (restarts the CLI, keeping the conversation)")
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = model.liveSession(meta.id) {
            // Key by the Session's object identity: a permissions flip swaps in a
            // brand-new Session (same juancode id) behind the same pty, so this
            // forces a fresh terminal that subscribes to the new pty and replays
            // the carried-forward scrollback.
            SwiftTermLive(session: session)
                .id(ObjectIdentifier(session))
        } else {
            SwiftTermReplay(scrollback: model.scrollback(meta.id))
        }
    }
}

struct NewSessionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ProviderId = .claude
    @State private var cwd: String = Config.defaultCwd
    @State private var skipPermissions = false
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
                }
                Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
                Toggle("Isolate in a fresh git worktree", isOn: $isolateWorktree)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || cwd.trimmingCharacters(in: .whitespaces).isEmpty)
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
