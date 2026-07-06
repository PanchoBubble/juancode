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
        if model.worktreeGroups.isEmpty && model.workAtRiskList.isEmpty {
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
                    workAtRiskSection
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
                                WorktreeRow(
                                    wt: wt, inUse: model.worktreeInUse(wt.path),
                                    atRisk: model.workAtRiskByPath[WorkAtRiskScan.normalize(wt.path)] != nil
                                ) { confirmRemove = wt }
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

    /// Work-at-risk section (juancode-rxu): folders holding uncommitted/unpushed
    /// work, including orphaned worktrees whose sessions are gone. Sits atop the
    /// worktree list so forgotten work is the first thing you see here.
    @ViewBuilder private var workAtRiskSection: some View {
        let list = model.workAtRiskList
        if !list.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Text("Work at risk (\(list.count))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ForEach(list) { risk in
                WorkAtRiskRow(
                    risk: risk,
                    newSession: { model.createInFolder(provider: .claude, cwd: risk.path); dismiss() },
                    reveal: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: risk.path)])
                    })
                Divider()
            }
        }
    }
}

/// One folder holding at-risk work: name, path, branch, and tags describing how
/// it's at risk, with actions to open a session there or reveal it in Finder.
private struct WorkAtRiskRow: View {
    let risk: WorkAtRisk
    let newSession: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: risk.orphaned ? "arrow.triangle.branch" : "pencil.and.list.clipboard")
                .font(.system(size: 12)).foregroundStyle(.orange).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((risk.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(risk.path)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let b = risk.branch {
                Text(b).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).help("Branch")
            }
            if risk.dirtyFiles > 0 { tag("\(risk.dirtyFiles) dirty", .orange) }
            if risk.ahead > 0 { tag("\(risk.ahead) unpushed", .orange) }
            if risk.noUpstream { tag("no upstream", .secondary) }
            if risk.orphaned { tag("orphaned", .red) }
            Button(action: newSession) { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless).help("New session in this folder").clickCursor()
            Button(action: reveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Reveal in Finder").clickCursor()
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
    /// This worktree holds uncommitted/unpushed work (juancode-rxu).
    var atRisk: Bool = false
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
            if atRisk {
                tag("at risk", .orange)
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
    /// Pending "kill this stuck agent" confirmation (juancode-101).
    @State private var confirmingKill = false

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
                // A stale session is live but stuck (busy, no output) — offer a
                // direct force-terminate so it doesn't have to be hunted down in
                // the sidebar (juancode-101).
                if report.state == .stale {
                    Button("Kill") { confirmingKill = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .help("Force-terminate this stuck agent (keeps the session so you can inspect it)")
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
        .confirmationDialog(
            "Kill the agent in \(meta?.title ?? report.id)?",
            isPresented: $confirmingKill, titleVisibility: .visible
        ) {
            Button("Kill Agent", role: .destructive) { model.killSession(report.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops the running agent immediately. The session and its output are kept so you can inspect what happened.")
        }
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

// MARK: - Recurring tasks (juancode-46g)

/// Create / manage panel for the recurring-task scheduler (engine from juancode-dgp).
/// Lets you register a task (folder + agent + prompt + interval), see when each
/// next fires and last fired, pause/resume, run on demand, and delete. The scheduler
/// itself lives in `AppModel`; this is purely its surface.
struct RecurringTasksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recurring Tasks").font(.title3).bold()
                Spacer()
                Button {
                    withAnimation { showingCreate.toggle() }
                } label: {
                    Label(showingCreate ? "Close" : "New Task",
                          systemImage: showingCreate ? "xmark" : "plus")
                }
                .clickCursor()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            if showingCreate {
                RecurringTaskCreateForm { showingCreate = false }
                Divider()
            }
            if model.recurringTasksList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "repeat").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recurring tasks.").foregroundStyle(.secondary).font(.system(size: 13))
                    Text("A recurring task re-runs a prompt in a project on a fixed\ninterval — each run spawns a fresh agent session.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.recurringTasksList) { task in
                            RecurringTaskRow(task: task) { dismiss() }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 480)
    }
}

/// One row in the management list: what/where/how-often plus its schedule status and
/// the per-task actions (run now, pause/resume, delete).
private struct RecurringTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: RecurringTask
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: task.enabled ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(task.enabled ? Color.green : Color.secondary)
                Text(task.title).font(.system(size: 13)).lineLimit(1).help(task.title)
                tag(Providers.spec(for: task.provider).label, .blue)
                tag("every \(humanInterval(task.intervalSeconds))", .secondary)
                if !task.enabled { tag("Paused", .orange) }
                Spacer(minLength: 8)
                Text((task.cwd as NSString).lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help(task.cwd)
            }
            Text(task.prompt).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).help(task.prompt)
            HStack(spacing: 12) {
                Text(scheduleLine).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Run now") { dismiss(); Task { await model.runRecurringTaskNow(task.id) } }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Spawn a session for this task right now")
                    .clickCursor()
                Button(task.enabled ? "Pause" : "Resume") {
                    model.setRecurringTaskEnabled(task.id, enabled: !task.enabled)
                }
                .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Delete", role: .destructive) { model.removeRecurringTask(task.id) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .foregroundStyle(.red).clickCursor()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var scheduleLine: String {
        let next = task.enabled ? "Next \(relativeTime(task.nextFireAt))" : "Paused"
        if let last = task.lastFiredAt {
            return "\(next) · last ran \(relativeTime(last))"
        }
        return "\(next) · never run yet"
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// The inline create form: a title, agent, folder, prompt and interval. Mirrors
/// `NewSessionView`'s field set but persists a schedule instead of spawning once.
private struct RecurringTaskCreateForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var title = ""
    @State private var provider: ProviderId = .claude
    @State private var cwd: String = Config.defaultCwd
    @State private var prompt = ""
    @State private var amount = 30
    @State private var unit: IntervalUnit = .minutes
    @State private var skipPermissions = true
    @State private var showingDirPicker = false

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool {
        !trimmedPrompt.isEmpty && !cwd.trimmingCharacters(in: .whitespaces).isEmpty && amount >= 1
    }

    var body: some View {
        Form {
            TextField("Title (optional)", text: $title)
            Picker("Agent", selection: $provider) {
                ForEach(ProviderId.allCases, id: \.self) { p in
                    Text(Providers.spec(for: p).label).tag(p)
                }
            }
            HStack {
                TextField("Working directory", text: $cwd)
                Button("Choose…") { showingDirPicker = true }.clickCursor()
            }
            TextField("Prompt", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
            HStack {
                Text("Every")
                TextField("", value: $amount, format: .number)
                    .frame(width: 60).multilineTextAlignment(.trailing)
                Picker("", selection: $unit) {
                    ForEach(IntervalUnit.allCases, id: \.self) { u in Text(u.label).tag(u) }
                }
                .labelsHidden().frame(width: 110)
                Spacer()
            }
            Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
            HStack {
                Spacer()
                Button("Create") { create() }
                    .disabled(!canCreate).keyboardShortcut(.defaultAction).clickCursor()
            }
        }
        .padding()
        .fileImporter(isPresented: $showingDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let needsScope = url.startAccessingSecurityScopedResource()
                cwd = url.path
                if needsScope { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func create() {
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(trimmedPrompt.prefix(48))
            : title.trimmingCharacters(in: .whitespaces)
        model.addRecurringTask(
            title: resolvedTitle, cwd: cwd, provider: provider, prompt: trimmedPrompt,
            intervalSeconds: amount * unit.seconds, skipPermissions: skipPermissions)
        done()
    }
}

/// Interval unit for the create form; multiplies the entered amount into seconds.
private enum IntervalUnit: String, CaseIterable {
    case minutes, hours, days
    var label: String { rawValue }
    var seconds: Int {
        switch self {
        case .minutes: return 60
        case .hours: return 3600
        case .days: return 86_400
        }
    }
}

/// A coarse "every N units" label for an interval expressed in seconds.
private func humanInterval(_ seconds: Int) -> String {
    if seconds % 86_400 == 0, seconds >= 86_400 { return plural(seconds / 86_400, "day") }
    if seconds % 3600 == 0, seconds >= 3600 { return plural(seconds / 3600, "hour") }
    if seconds % 60 == 0, seconds >= 60 { return plural(seconds / 60, "min") }
    return plural(seconds, "sec")
}

private func plural(_ n: Int, _ unit: String) -> String {
    "\(n) \(unit)\(n == 1 ? "" : "s")"
}

/// A relative date string ("in 5 min", "2 hr ago") for a ms-since-epoch timestamp.
func relativeTime(_ msEpoch: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(msEpoch) / 1000)
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: Date())
}
