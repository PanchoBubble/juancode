import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

// MARK: - Worktrees (juancode-q6q)

/// One repo's worktrees: its main worktree (the project root) and the linked
/// `juancode/*` worktrees beneath it. Used to group the cleanup sheet by project.
struct WorktreeGroup: Identifiable {
    let main: Worktree
    let children: [Worktree]
    var id: String { main.path }
    /// Project label — the repo's folder name.
    var name: String { (main.path as NSString).lastPathComponent }
}

/// A sheet to review and clean up git worktrees across the repos you're working in
/// — the easy "clean worktrees" affordance. Groups worktrees by project: each repo
/// is a collapsible section headed by its main worktree, with the linked `juancode/*`
/// worktrees beneath it. Flags those a live session is still using, and removes the
/// rest with a confirmation.
struct WorktreesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove: Worktree?
    /// Repo ids (main worktree paths) the user has collapsed; expanded by default.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Worktrees").font(.title3).bold()
                if model.worktreesLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button { model.loadWorktrees() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan").clickCursor()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 640, height: 460)
        .onAppear { model.loadWorktrees() }
        .alert("Remove worktree?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmRemove = nil }
            Button("Remove", role: .destructive) {
                if let wt = confirmRemove { model.removeWorktreeAt(wt.path) }
                confirmRemove = nil
            }
        } message: {
            Text("This deletes the worktree directory — uncommitted changes there are lost. "
                + "The branch is kept.\n\n\(confirmRemove?.path ?? "")")
        }
    }

    @ViewBuilder private var content: some View {
        if model.worktreeGroups.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.worktreesLoading
                     ? "Scanning…"
                     : "No worktrees found in the repos you're working in.")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.worktreeGroups) { group in
                        WorktreeProjectHeader(
                            group: group,
                            collapsed: collapsed.contains(group.id),
                            inUse: model.worktreeInUse(group.main.path)
                        ) {
                            if collapsed.contains(group.id) { collapsed.remove(group.id) }
                            else { collapsed.insert(group.id) }
                        }
                        Divider()
                        if !collapsed.contains(group.id) {
                            ForEach(group.children, id: \.path) { wt in
                                WorktreeRow(wt: wt, inUse: model.worktreeInUse(wt.path)) { confirmRemove = wt }
                                Divider()
                            }
                            if group.children.isEmpty {
                                Text("No linked worktrees")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 38).padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Collapsible per-project header: the repo's main worktree. Shows the project
/// (folder) name, full path, branch, a "main" tag, and a child count.
private struct WorktreeProjectHeader: View {
    let group: WorktreeGroup
    let collapsed: Bool
    let inUse: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 16)
                Image(systemName: "house.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(group.main.path)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let b = group.main.branch {
                    Text(b).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).help("Branch")
                }
                if !group.children.isEmpty {
                    Text("\(group.children.count)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2)).foregroundStyle(.secondary)
                        .clipShape(Capsule())
                        .help("\(group.children.count) linked worktree(s)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }
}

private struct WorktreeRow: View {
    let wt: Worktree
    let inUse: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: wt.main ? "house.fill" : "arrow.triangle.branch")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((wt.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(wt.path)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let b = wt.branch {
                Text(b).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).help("Branch")
            }
            if wt.main {
                tag("main", .secondary)
            } else if inUse {
                tag("in use", .blue)
            }
            if !wt.main {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(inUse ? "A live session uses this worktree — removing it will disrupt it"
                                : "Remove worktree")
                    .clickCursor()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Tracked PRs (juancode-38z)

/// The global view of every PR under watch and its CI-fix loop state. Tracking is
/// started from a folder's PR list ("Track"); this panel lets you see them all in
/// one place, jump to the driving session, untrack, and clear surfaced decisions.
struct TrackedPrsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracked PRs").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            if model.trackedList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No PRs tracked yet.").foregroundStyle(.secondary).font(.system(size: 13))
                    Text("Open a folder's PR list and hit “Track” to start a CI-fix loop:\nthe agent watches the PR and auto-fixes lint/CI, escalating real decisions.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.trackedList) { pr in
                            TrackedPrRow(pr: pr) { dismiss() }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 660, height: 480)
    }
}

private struct TrackedPrRow: View {
    @Environment(AppModel.self) private var model
    let pr: TrackedPr
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(pr.number)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 13)).lineLimit(1).help(pr.title)
                TrackBadge(state: pr.state)
                Spacer(minLength: 8)
                Text((pr.cwd as NSString).lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Text(pr.branch).font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Button("Open ↗") {
                    if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Go to session") { dismiss(); model.selection = pr.sessionId }
                    .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Untrack") { model.untrackPr(pr.id) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Stop watching this PR (keeps the session)").clickCursor()
            }
            ForEach(pr.notifications) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Text(note.message).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("Dismiss") {
                        model.resolveNotification(prId: pr.id, notificationId: note.id)
                    }
                    .buttonStyle(.borderless).font(.system(size: 9)).clickCursor()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Tracked Linear issues (juancode-7sa)

/// The global view of every Linear issue under watch — the twin of `TrackedPrsSheet`.
/// Start tracking a new issue (type its id or pick one assigned to you, choosing the
/// folder its agent session runs in), see each one's workflow-state badge and surfaced
/// decisions, jump to the driving session, and untrack.
struct TrackedIssuesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracked Issues").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            TrackIssueEntry()
            Divider()
            if model.trackedIssuesList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "ticket").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No Linear issues tracked yet.").foregroundStyle(.secondary).font(.system(size: 13))
                    Text("Enter an issue id (or pick one assigned to you) above and choose a folder\nto start a do-or-escalate loop: the agent watches the issue, acts on new\nactivity, and escalates the real decisions back to you.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.trackedIssuesList) { issue in
                            TrackedIssueRow(issue: issue) { dismiss() }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 660, height: 520)
    }
}

/// The "start tracking" affordance at the top of the issues panel: an id field + a
/// folder picker (the agent runs there) wired to `AppModel.trackIssue`, plus an
/// optional "Assigned to me" list that fills the id field from your Linear issues.
private struct TrackIssueEntry: View {
    @Environment(AppModel.self) private var model
    @State private var identifier = ""
    @State private var folder = ""
    @State private var showingAssigned = false

    private var folders: [String] { model.trackableFolders }
    private var canTrack: Bool {
        !identifier.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Issue id (e.g. ENG-123)", text: $identifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 170)
                    .onSubmit(track)
                Menu {
                    ForEach(folders, id: \.self) { f in
                        Button((f as NSString).lastPathComponent) { folder = f }
                    }
                } label: {
                    Text(folder.isEmpty ? "Folder…" : (folder as NSString).lastPathComponent)
                        .font(.system(size: 12)).lineLimit(1)
                }
                .frame(maxWidth: 170)
                .disabled(folders.isEmpty)
                .help(folder.isEmpty ? "Choose the folder the tracking agent runs in" : folder)
                Button("Track", action: track)
                    .disabled(!canTrack)
                    .clickCursor()
                Spacer()
                Button {
                    showingAssigned.toggle()
                    if showingAssigned && model.assignedIssues.isEmpty { model.loadAssignedIssues() }
                } label: {
                    Label("Assigned to me", systemImage: "person.crop.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Pick from issues assigned to you in Linear")
                .clickCursor()
            }
            if showingAssigned { assignedList }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear { if folder.isEmpty { folder = folders.first ?? "" } }
    }

    @ViewBuilder private var assignedList: some View {
        if model.assignedIssuesLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading assigned issues…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if model.assignedIssues.isEmpty {
            Text("No open issues assigned to you (or no Linear token set).")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.assignedIssues) { issue in
                        Button { identifier = issue.identifier } label: {
                            HStack(spacing: 6) {
                                Text(issue.identifier)
                                    .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                                Text(issue.title).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 4)
                                if !issue.stateName.isEmpty {
                                    Text(issue.stateName).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .clickCursor()
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func track() {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !folder.isEmpty else { return }
        model.trackIssue(identifier: id, cwd: folder)
        identifier = ""
    }
}

private struct TrackedIssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: TrackedIssue
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(issue.identifier).font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                Text(issue.title).font(.system(size: 13)).lineLimit(1).help(issue.title)
                IssueTrackBadge(state: issue.state)
                Spacer(minLength: 8)
                Text((issue.cwd as NSString).lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                if !issue.lastStateName.isEmpty {
                    Text(issue.lastStateName).font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Open ↗") {
                    if let u = URL(string: issue.url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Go to session") { dismiss(); model.selection = issue.sessionId }
                    .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Untrack") { model.untrackIssue(issue.id) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Stop watching this issue (keeps the session)").clickCursor()
            }
            ForEach(issue.notifications) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Text(note.message).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("Dismiss") {
                        model.resolveIssueNotification(issueId: issue.id, notificationId: note.id)
                    }
                    .buttonStyle(.borderless).font(.system(size: 9)).clickCursor()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// A small pill showing what a tracked Linear issue is currently doing — the twin of
/// `TrackBadge`, over `IssueTrackState`.
struct IssueTrackBadge: View {
    let state: IssueTrackState
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
        case .active: return "active"
        case .needsDecision: return "needs you"
        case .done: return "done"
        }
    }
    private var color: Color {
        switch state {
        case .watching: return .secondary
        case .active: return .blue
        case .needsDecision: return .orange
        case .done: return .green
        }
    }
    private var help: String {
        switch state {
        case .watching: return "Tracking — watching for new activity"
        case .active: return "Tracking — the issue is in progress"
        case .needsDecision: return "Tracking — a change needs your decision"
        case .done: return "Tracking — the issue reached a terminal state"
        }
    }
}

// MARK: - Session health (juancode-0me pillar 3 / juancode-02k)

/// The global view of sessions the periodic health sweep flagged as dead (their pty
/// is gone) or stale (busy with no output for a long time — a likely hang). Offers
/// reactivation for resumable dead ones, a jump to the session, and dismissal.
struct SessionHealthSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session Health").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            if model.unhealthySessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "heart.text.square").font(.largeTitle).foregroundStyle(.secondary)
                    Text("All sessions healthy.").foregroundStyle(.secondary).font(.system(size: 13))
                    Text("This panel flags sessions that died (pty exited) or stalled\n(busy with no output for a while), and offers to revive them.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.unhealthySessions, id: \.id) { report in
                            SessionHealthRow(report: report) { dismiss() }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 620, height: 440)
    }
}

private struct SessionHealthRow: View {
    @Environment(AppModel.self) private var model
    let report: SessionHealthReport
    let dismiss: () -> Void

    /// The persisted meta for this session, for its title + folder.
    private var meta: SessionMeta? { model.sessions.first { $0.id == report.id } }

    private var stateLabel: (text: String, color: Color, icon: String) {
        switch report.state {
        case .dead: return ("Dead", .red, "xmark.octagon.fill")
        case .stale: return ("Stale", .orange, "clock.badge.exclamationmark.fill")
        case .healthy: return ("Healthy", .green, "checkmark.circle.fill")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let label = stateLabel
                Image(systemName: label.icon).font(.system(size: 10)).foregroundStyle(label.color)
                Text(meta?.title ?? report.id).font(.system(size: 13)).lineLimit(1)
                    .help(meta?.title ?? report.id)
                tag(label.text, label.color)
                Spacer(minLength: 8)
                if let cwd = meta?.cwd {
                    Text((cwd as NSString).lastPathComponent)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if report.state == .dead {
                    Button(report.resumable ? "Reactivate" : "Reactivate…") {
                        model.reactivateUnhealthy(report.id)
                    }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help(report.resumable
                          ? "Resume this session's CLI conversation"
                          : "Try to recover and resume this session")
                    .clickCursor()
                }
                Button("Go to session") { dismiss(); model.selection = report.id }
                    .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Dismiss") { model.dismissHealth(report.id) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Stop flagging this session (until it recovers and fails again)")
                    .clickCursor()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var reason: String {
        switch report.state {
        case .dead: return "The session's process exited — its prompt may never have finished."
        case .stale: return "Busy with no output for a while — the turn looks stuck."
        case .healthy: return ""
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}
