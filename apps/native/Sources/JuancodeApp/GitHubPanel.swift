import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices
import MarkdownUI

// The first-class GitHub view (juancode-2t6): overlays the detail area of the
// split view (never a sheet — the session content stays mounted underneath,
// juancode-073) listing every open PR grouped by project folder. Selecting a PR
// loads its conversation + checks into the detail pane (juancode-1au): header
// actions, needs-decision notifications, CI checks with failing logs, and the
// full conversation — replyable inline and hand-off-able to the agent.

/// Selection + per-PR caches for the GitHub view, owned by `AppModel` so they
/// survive the view being dismissed and re-opened. Keys are
/// `TrackedPr.key(cwd:number:)` ("<cwd>#<number>").
@MainActor
@Observable
final class GitHubModel {
    /// The selected PR's key, or nil when nothing is selected.
    var selectedKey: String?
    /// Fetched conversations (comments / reviews / inline threads) per PR.
    private(set) var conversations: [String: PrConversation] = [:]
    /// Fetched CI check runs per PR.
    private(set) var checks: [String: [PrCheckRun]] = [:]
    /// Fetched PR diffs per PR, for the detail's Diff tab (fetched lazily the first
    /// time that tab is shown; cached for the app's lifetime).
    private(set) var diffs: [String: DiffResult] = [:]
    /// PR keys with a diff fetch in flight, so the tab doesn't stampede `gh pr diff`.
    private(set) var diffLoading: Set<String> = []
    /// PR keys with a detail fetch in flight, so selection doesn't stampede.
    private(set) var loading: Set<String> = []
    /// Failing-step CI logs per PR (fetched once, on demand — "Show logs").
    private(set) var ciLogs: [String: String] = [:]
    /// PR keys with a CI-log fetch in flight (spinner on the checks row).
    private(set) var ciLogsLoading: Set<String> = []
    /// PR keys with a `gh run rerun` in flight (disables the rerun buttons).
    private(set) var rerunning: Set<String> = []
    /// Timeline-item ids briefly flashing a "Queued" confirmation after a
    /// successful "Send to agent".
    private(set) var queuedFlash: Set<String> = []
    /// The last action failure to surface inline (send-to-agent/track errors).
    var actionError: String?
    /// Viewer-scoped filters shared across every folder in the pane. Mirror the
    /// folder popover's Mine/Assigned semantics (AND when both are on), and live
    /// here so they persist while the view is dismissed and re-opened.
    var mineOnly = false
    var assignedOnly = false

    /// Whether any viewer-scoped filter is active.
    var filterActive: Bool { mineOnly || assignedOnly }

    /// Apply the active filters to a folder's PRs using that folder's viewer
    /// login. Returns the list unchanged when no filter is active or the viewer
    /// is unknown, so a folder never hides its PRs just because `gh` couldn't
    /// report who we are.
    func filtered(_ prs: [PullRequest], viewer: String) -> [PullRequest] {
        guard filterActive, !viewer.isEmpty else { return prs }
        return prs.filter { pr in
            if mineOnly && pr.author != viewer { return false }
            if assignedOnly && !pr.assignees.contains(viewer) { return false }
            return true
        }
    }

    /// Kick a PR-list refresh for every folder the view shows (all, or the one
    /// scoped folder). Re-runs the scoped `gh` query too when a filter is active,
    /// since `loadPrs` resets the cache to the newest-100 firehose (which may miss
    /// your older PRs).
    func refresh(model: AppModel) {
        for cwd in model.githubScopedFolders {
            model.loadPrs(cwd)
            if filterActive {
                model.backfillPrs(cwd, mine: mineOnly, assigned: assignedOnly, query: "")
            }
        }
    }

    /// Re-run the scoped backfill for every folder — called when a filter toggles
    /// so matches beyond the firehose fold in.
    func applyFilters(model: AppModel) {
        for cwd in model.githubScopedFolders {
            model.backfillPrs(cwd, mine: mineOnly, assigned: assignedOnly, query: "")
        }
    }

    /// Select a PR and prefetch its detail.
    func select(cwd: String, pr: PullRequest) {
        selectedKey = TrackedPr.key(cwd: cwd, number: pr.number)
        loadDetail(cwd: cwd, pr: pr)
    }

    /// Fetch the PR's conversation + check runs off the main actor (both shell
    /// out to `gh`) and publish back here. Coalesces per PR; a failed
    /// conversation fetch keeps any previously cached one.
    func loadDetail(cwd: String, pr: PullRequest) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        let number = pr.number
        let url = pr.url
        Task {
            async let conversation = Task.detached(priority: .utility) {
                await getPrConversation(cwd, number: number, prUrl: url)
            }.value
            async let runs = Task.detached(priority: .utility) {
                await getPrCheckRuns(cwd, number: number)
            }.value
            let (c, r) = await (conversation, runs)
            if let c { conversations[key] = c }
            checks[key] = r
            loading.remove(key)
        }
    }

    /// Fetch the PR's diff (`gh pr diff --patch`, split into per-file `DiffFile`s)
    /// for the detail's Diff tab. Off-main; cached per PR and coalesced so re-opening
    /// the tab is instant. A failed fetch leaves the cache empty so the tab retries.
    func loadDiff(cwd: String, pr: PullRequest) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard diffs[key] == nil, !diffLoading.contains(key) else { return }
        diffLoading.insert(key)
        let number = pr.number
        Task {
            let result = await Task.detached(priority: .utility) {
                try? await getPrDiff(cwd, number: number)
            }.value
            if let result { diffs[key] = result }
            diffLoading.remove(key)
        }
    }

    /// Fetch the failing-step CI logs for a PR (once — cached until the app
    /// restarts; the checks row offers a reload). Off-main: shells into
    /// `gh run view --log-failed` per failing run.
    func loadCiLogs(cwd: String, pr: PullRequest) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !ciLogsLoading.contains(key) else { return }
        ciLogsLoading.insert(key)
        let number = pr.number
        Task {
            let logs = await Task.detached(priority: .utility) {
                await getFailedCheckLogs(cwd, number: number)
            }.value
            ciLogs[key] = logs.isEmpty ? "No failing-step logs available." : logs
            ciLogsLoading.remove(key)
        }
    }

    /// Re-run a PR's CI checks via `gh run rerun` (`failedOnly` → "Re-run failed
    /// jobs", else "Re-run all jobs"). Off-main; on success refetches the check
    /// runs so the row reflects the re-queued state, else surfaces the error.
    func rerunChecks(cwd: String, pr: PullRequest, failedOnly: Bool) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !rerunning.contains(key) else { return }
        rerunning.insert(key)
        actionError = nil
        let number = pr.number
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try await JuancodeServices.rerunChecks(cwd, number: number, failedOnly: failedOnly)
                }.value
                loadDetail(cwd: cwd, pr: pr)
            } catch let e as GhError {
                actionError = e.message
            } catch {
                actionError = error.localizedDescription
            }
            rerunning.remove(key)
        }
    }

    /// Post a reply: a review-thread reply when `replyTargetId` is set (the
    /// thread's first comment's REST id — GitHub's replies API only accepts
    /// top-level review comments), else a top-level PR comment. Returns the
    /// error message to surface inline, or nil on success — in which case the
    /// conversation is refetched so the new comment appears.
    func postReply(cwd: String, pr: PullRequest, replyTargetId: Int?, body: String) async -> String? {
        let number = pr.number
        do {
            try await Task.detached(priority: .utility) {
                if let target = replyTargetId {
                    try await replyToReviewComment(cwd, number: number, commentId: target, body: body)
                } else {
                    try await commentOnPr(cwd, number: number, body: body)
                }
            }.value
            loadDetail(cwd: cwd, pr: pr)
            return nil
        } catch let e as GhError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }

    /// "Send to agent" on a tracked PR: queue the comment-task prompt on the
    /// tracking session via its message queue (idle-edge delivery, same as
    /// `submitReview`) and flash a transient confirmation on the item.
    func sendToAgent(appModel: AppModel, cwd: String, pr: PullRequest, prompt: String, itemId: String) {
        guard let t = appModel.trackedPr(cwd: cwd, number: pr.number) else {
            actionError = "PR #\(pr.number) isn't tracked — use Track & send."
            return
        }
        appModel.queuePrompt(sessionId: t.sessionId, text: prompt)
        flashQueued(itemId)
    }

    /// "Track & send" on an untracked PR: start tracking (spawns the seeded
    /// agent session), then queue the prompt on it.
    func trackAndSend(appModel: AppModel, cwd: String, pr: PullRequest, prompt: String, itemId: String) {
        Task {
            if await appModel.trackPrAndQueue(pr, cwd: cwd, prompt: prompt) {
                flashQueued(itemId)
            } else {
                actionError = "Couldn't track PR #\(pr.number) — the agent session failed to spawn."
            }
        }
    }

    /// Compose the diff-review basket staged for this PR (line notes added in the
    /// Diff tab, keyed by the PR key so they survive tab/PR switches) into one
    /// feedback prompt and route it to the agent — queued on the tracking session
    /// when tracked, else tracked-and-queued. Clears the basket on a successful
    /// hand-off and flashes a confirmation on the bar.
    func sendDiffReview(appModel: AppModel, cwd: String, pr: PullRequest) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        let staged = appModel.comments(key)
        let feedback = composeReviewFeedback(staged)
        guard !feedback.isEmpty else { return }
        let prompt = diffReviewPrompt(number: pr.number, url: pr.url, feedback: feedback)
        if let t = appModel.trackedPr(cwd: cwd, number: pr.number) {
            appModel.queuePrompt(sessionId: t.sessionId, text: prompt)
            appModel.discardComments(key)
            flashQueued(key)
        } else {
            Task {
                if await appModel.trackPrAndQueue(pr, cwd: cwd, prompt: prompt) {
                    appModel.discardComments(key)
                    flashQueued(key)
                } else {
                    actionError = "Couldn't track PR #\(pr.number) — the agent session failed to spawn."
                }
            }
        }
    }

    /// Show "Queued" next to the item for a moment, then clear it.
    private func flashQueued(_ itemId: String) {
        queuedFlash.insert(itemId)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            queuedFlash.remove(itemId)
        }
    }
}

/// The GitHub view: header bar + two columns (folder-grouped PR list, detail
/// pane). Fills the detail area with an opaque background — it overlays a live
/// terminal pane, so nothing may bleed through.
struct GitHubView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if canFilterViewer {
                filterBar
                Divider()
            }
            HStack(spacing: 0) {
                prList
                    .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appSurface)
        .onExitCommand { model.showingGitHub = false }
        // Opening with a filter still active (persisted across dismiss/reopen): fold
        // in the matches beyond the newest-100 firehose so the count is right from the
        // start, without waiting for a manual refresh or a filter re-toggle.
        .task { if model.github.filterActive { model.github.applyFilters(model: model) } }
        // Deep-link resolution: once the scoped folder's PRs load, select the
        // pending current-branch PR (openGitHubForFolder recorded it).
        .onChange(of: scopedPrCountSignal) { _, _ in model.resolvePendingBranchSelect() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Label("GitHub", systemImage: "arrow.triangle.pull")
                .font(.system(size: 14, weight: .semibold))
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if model.githubScope != nil {
                Button { model.openGitHub(scope: nil) } label: {
                    Label("All projects", systemImage: "square.grid.2x2")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Show PRs across every project")
                .clickCursor()
            }
            Button { model.github.refresh(model: model) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh open PRs")
            .clickCursor()
            Button { model.showingGitHub = false } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .clickCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: filter bar

    /// Viewer-scoped filters, in their own full-width row under the header.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle("Mine (\(mineCount))", isOn: mineBinding)
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 10))
                .help("Show only PRs you authored")
                .clickCursor()
            Toggle("Assigned (\(assignedCount))", isOn: assignedBinding)
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 10))
                .help("Show only PRs assigned to you")
                .clickCursor()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let folders = model.githubScopedFolders
        let total = scopedPrTotal
        let prPart = model.github.filterActive
            ? "\(shownPrTotal) of \(total) open PR\(total == 1 ? "" : "s")"
            : "\(total) open PR\(total == 1 ? "" : "s")"
        if let scope = model.githubScope {
            return "\((scope as NSString).lastPathComponent) · \(prPart)"
        }
        return "\(folders.count) folder\(folders.count == 1 ? "" : "s") · \(prPart)"
    }

    /// Changes when the scoped folder's PRs load, driving deep-link resolution.
    private var scopedPrCountSignal: Int {
        guard let scope = model.githubScope else { return -1 }
        return model.prs(scope)?.prs.count ?? -1
    }

    // MARK: viewer filters

    /// The authenticated `gh` login, taken from the first shown folder that
    /// reports one (auth is global, so it's the same across folders).
    private var viewer: String {
        for cwd in model.githubScopedFolders {
            if let v = model.prs(cwd)?.viewer, !v.isEmpty { return v }
        }
        return ""
    }

    /// Total open PRs across the folders currently shown (scope-aware).
    private var scopedPrTotal: Int {
        model.githubScopedFolders.reduce(0) { acc, cwd in
            guard let r = model.prs(cwd), r.available else { return acc }
            return acc + r.prs.count
        }
    }

    /// Offer the viewer-scoped filters only once we know who the viewer is and
    /// there's at least one open PR to filter (within the current scope).
    private var canFilterViewer: Bool { !viewer.isEmpty && scopedPrTotal > 0 }

    /// PRs authored by the viewer across the shown folders (each scored by its
    /// own viewer login).
    private var mineCount: Int {
        countAcrossFolders { pr, v in pr.author == v }
    }

    /// PRs assigned to the viewer across the shown folders.
    private var assignedCount: Int {
        countAcrossFolders { pr, v in pr.assignees.contains(v) }
    }

    /// Total PRs shown under the active filters, across the shown folders.
    private var shownPrTotal: Int {
        model.githubScopedFolders.reduce(0) { acc, cwd in
            guard let r = model.prs(cwd), r.available else { return acc }
            return acc + model.github.filtered(r.prs, viewer: r.viewer ?? "").count
        }
    }

    private func countAcrossFolders(_ match: (PullRequest, String) -> Bool) -> Int {
        model.githubScopedFolders.reduce(0) { acc, cwd in
            guard let r = model.prs(cwd), r.available, let v = r.viewer, !v.isEmpty else { return acc }
            return acc + r.prs.filter { match($0, v) }.count
        }
    }

    private var mineBinding: Binding<Bool> {
        Binding(
            get: { model.github.mineOnly },
            set: { model.github.mineOnly = $0; model.github.applyFilters(model: model) })
    }

    private var assignedBinding: Binding<Bool> {
        Binding(
            get: { model.github.assignedOnly },
            set: { model.github.assignedOnly = $0; model.github.applyFilters(model: model) })
    }

    // MARK: PR list (left column)

    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.githubScopedFolders, id: \.self) { cwd in
                    folderSection(cwd)
                }
                if model.githubScopedFolders.isEmpty {
                    Text("No project folders yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func folderSection(_ cwd: String) -> some View {
        let result = model.prs(cwd)
        let shown = result.map { model.github.filtered($0.prs, viewer: $0.viewer ?? "") } ?? []
        // Under an active filter, drop folders with no matches so the pane stays
        // focused on the PRs you asked for.
        if model.github.filterActive, let r = result, r.available, shown.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text((cwd as NSString).lastPathComponent)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .help(cwd)
                    Spacer(minLength: 4)
                    if let r = result, r.available {
                        Text("\(shown.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if result == nil {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appPanel)
                if let r = result {
                    if !r.available {
                        // e.g. "gh not authenticated" / not a GitHub repo.
                        Text(r.error ?? "PRs unavailable")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else if r.prs.isEmpty {
                        Text("No open PRs")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        let ordered = sortPrsBySubmitDate(shown)
                        ForEach(ordered, id: \.number) { pr in
                            GitHubPrRow(pr: pr, cwd: cwd)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: detail (right column)

    @ViewBuilder
    private var detail: some View {
        if let (cwd, pr) = selectedPr {
            GitHubPrDetail(pr: pr, cwd: cwd)
                .id(TrackedPr.key(cwd: cwd, number: pr.number))
        } else {
            ContentUnavailableView(
                "Select a pull request",
                systemImage: "arrow.triangle.pull",
                description: Text("Pick a PR on the left to see its conversation and checks.")
            )
        }
    }

    /// Resolve the selected key back to its (folder, PR) pair from the loaded
    /// lists — nil once the PR is no longer open (merged/closed on refresh).
    private var selectedPr: (String, PullRequest)? {
        guard let key = model.github.selectedKey else { return nil }
        for cwd in model.githubScopedFolders {
            guard let r = model.prs(cwd), r.available else { continue }
            if let pr = r.prs.first(where: { TrackedPr.key(cwd: cwd, number: $0.number) == key }) {
                return (cwd, pr)
            }
        }
        return nil
    }
}

/// One PR row in the left column. Reuses the visual language of the folder
/// popover's `PrRow` (CI dot, passed/total, draft badge, unresolved bubble,
/// `TrackBadge`); tap selects, actions live in the context menu + detail pane.
private struct GitHubPrRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }
    private var selected: Bool { model.github.selectedKey == key }

    var body: some View {
        Button {
            model.github.select(cwd: cwd, pr: pr)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(checkColor).frame(width: 7, height: 7)
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
                    if let t = tracked, !t.notifications.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("\(t.notifications.count) decision\(t.notifications.count == 1 ? "" : "s") need you")
                    }
                }
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: checkIcon).font(.system(size: 9))
                        Text(checksText).font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(checkColor)
                    if pr.unresolvedComments > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.fill").font(.system(size: 8))
                            Text("\(pr.unresolvedComments)").font(.system(size: 10))
                        }
                        .foregroundStyle(.orange)
                        .help("\(pr.unresolvedComments) unresolved comment\(pr.unresolvedComments == 1 ? "" : "s")")
                    }
                    if let t = tracked { TrackBadge(state: t.state) }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 13)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clickCursor()
        .contextMenu { GitHubPrActions(pr: pr, cwd: cwd) }
    }

    private var checkColor: Color {
        switch pr.checks {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        case .none: return .secondary
        }
    }

    private var checkIcon: String {
        switch pr.checks {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .none: return "minus.circle"
        }
    }

    private var checksText: String {
        pr.checkCount == 0 ? "No checks" : "\(pr.passedCount)/\(pr.checkCount)"
    }
}

/// The shared PR actions, rendered as context-menu items or detail-pane buttons:
/// Open in browser, Open diff, Track/Untrack, Go to session (tracked only).
private struct GitHubPrActions: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String

    var body: some View {
        let tracked = model.trackedPr(cwd: cwd, number: pr.number)
        Button("Open in Browser") {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        }
        Button("Open Diff") { model.openPrDiff(pr, cwd: cwd) }
        if let t = tracked {
            // `selection`'s didSet closes the GitHub view.
            Button("Go to Session") { model.selection = t.sessionId }
            Button("Untrack") { model.untrackPr(t.id) }
        } else {
            Button("Track") { model.trackPr(pr, cwd: cwd) }
        }
    }
}

// MARK: - PR detail pane (juancode-1au)

/// The two tabs the PR detail can show: the conversation timeline, or the PR's
/// diff rendered read-only.
private enum PrDetailTab: String, CaseIterable {
    case conversation, diff
    var label: String {
        switch self {
        case .conversation: return "Conversation"
        case .diff: return "Diff"
        }
    }
}

/// The PR diff, rendered with the same syntax-highlighted, comment-able `FileCard`
/// as the working-tree Changes panel — click a line (or drag-select a range) to
/// stage an inline note. Notes live in a per-PR review basket (keyed by the PR key,
/// so they survive tab and PR switches) and are handed to the agent in one batch via
/// the bar at the bottom. Fetched lazily via `GitHubModel.loadDiff` and cached.
///
/// Layout mirrors the Changes panel: a resizable file tree on the left, the diff
/// cards on the right. A path filter hides non-matching files everywhere; a content
/// filter washes matching diff lines and steps the selection between matching files.
private struct PrDiffTab: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    /// Which files are expanded — everything starts collapsed, like the Changes panel.
    @State private var expandedPaths: Set<String> = []
    /// Free-text filter over changed-file paths (hides non-matching files in the tree
    /// and the diff list).
    @State private var pathQuery = ""
    /// Free-text search over diff line content (highlights matching lines, drives jump).
    @State private var contentQuery = ""
    /// Directory node ids currently expanded in the tree.
    @State private var treeExpanded: Set<String> = []
    /// The file selected in the tree — the diff list scrolls to it.
    @State private var selectedPath: String?
    /// Index into `matchingPaths` for the content-search jump buttons.
    @State private var matchCursor = 0
    /// Persisted width of the tree pane and whether it's shown (shared defaults with
    /// the Changes panel so the split feels consistent across the two diff surfaces).
    @AppStorage("changes.treeWidth") private var treeWidth: Double = 260
    @AppStorage("changes.treeShown") private var treeShown: Bool = true

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    private var result: DiffResult? { model.github.diffs[key] }
    private var loading: Bool { model.github.diffLoading.contains(key) }

    /// The normalized content query (empty when no search is active).
    private var contentQ: String { contentQuery.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Files surviving the path filter, in diff order.
    private var visibleFiles: [DiffFile] {
        let q = pathQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let files = result?.files ?? []
        return q.isEmpty ? files : files.filter { $0.path.lowercased().contains(q) }
    }

    private var tree: [FileTreeNode] { buildFileTree(visibleFiles) }
    private var allDirIDs: Set<String> { directoryNodeIDs(tree) }

    /// Paths (in diff order) whose diff body contains the content query — the jump
    /// targets and the set auto-expanded so their highlighted lines are visible.
    private var matchingPaths: [String] {
        guard !contentQ.isEmpty else { return [] }
        return visibleFiles.filter { $0.diff.lowercased().contains(contentQ) }.map(\.path)
    }

    var body: some View {
        VStack(spacing: 8) {
            content
            reviewBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .onAppear { model.github.loadDiff(cwd: cwd, pr: pr) }
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            if result.files.isEmpty {
                leading("No file changes.")
            } else {
                VStack(spacing: 6) {
                    if result.truncatedFiles == true {
                        Text("Showing the first \(result.files.count) files — open the PR in your browser for the rest.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    filtersRow
                    splitView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading diff…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            leading("Couldn't load the diff.")
        }
    }

    // MARK: filters

    /// The two filters plus the content-search match counter and jump chevrons.
    private var filtersRow: some View {
        HStack(spacing: 8) {
            Button { treeShown.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(treeShown ? Color.accentColor : .secondary)
            .help(treeShown ? "Hide the file tree" : "Show the file tree")
            .clickCursor()

            TextField("Filter files…", text: $pathQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(maxWidth: 200)

            HStack(spacing: 4) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search in diff…", text: $contentQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { jumpMatch(1) }
                if !contentQ.isEmpty {
                    Text(matchingPaths.isEmpty
                         ? "no matches"
                         : "\(min(matchCursor + 1, matchingPaths.count))/\(matchingPaths.count) file\(matchingPaths.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize()
                    Button { jumpMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).clickCursor()
                        .disabled(matchingPaths.isEmpty)
                        .help("Previous file with a match")
                    Button { jumpMatch(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).clickCursor()
                        .disabled(matchingPaths.isEmpty)
                        .help("Next file with a match")
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: contentQ) { _, _ in
            // A new search jumps to (and expands) the first hit.
            matchCursor = 0
            if let first = matchingPaths.first { selectedPath = first }
        }
    }

    /// Step the selection to the next/prev file that contains a content match, wrapping
    /// at the ends. Selecting the path scrolls to and expands that card.
    private func jumpMatch(_ delta: Int) {
        let paths = matchingPaths
        guard !paths.isEmpty else { return }
        let start = selectedPath.flatMap { paths.firstIndex(of: $0) } ?? -1
        let next = ((start + delta) % paths.count + paths.count) % paths.count
        matchCursor = next
        selectedPath = paths[next]
    }

    // MARK: tree | diff split

    private var splitView: some View {
        HStack(spacing: 0) {
            if treeShown {
                treePane.frame(width: CGFloat(treeWidth))
                DragResizeHandle(axis: .vertical, value: $treeWidth, min: 160, max: 520, invert: false)
            }
            diffPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var treePane: some View {
        if visibleFiles.isEmpty {
            Text("No files match “\(pathQuery)”.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(8)
        } else {
            VStack(spacing: 0) {
                treePaneHeader
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree) { node in
                            FileTreeRows(
                                node: node,
                                depth: 0,
                                viewedPaths: [],
                                selectedPath: $selectedPath,
                                expanded: $treeExpanded)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }

    private var treePaneHeader: some View {
        let dirs = allDirIDs
        return HStack(spacing: 4) {
            Spacer()
            Button { treeExpanded = [] } label: { Image(systemName: "rectangle.compress.vertical") }
                .buttonStyle(.borderless)
                .help("Collapse all folders")
                .disabled(dirs.isEmpty || treeExpanded.isEmpty)
                .clickCursor()
            Button { treeExpanded = dirs } label: { Image(systemName: "rectangle.expand.vertical") }
                .buttonStyle(.borderless)
                .help("Expand all folders")
                .disabled(dirs.isEmpty || treeExpanded == dirs)
                .clickCursor()
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder
    private var diffPane: some View {
        if visibleFiles.isEmpty {
            leading("No files match “\(pathQuery)”.")
        } else {
            let matches = Set(matchingPaths)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleFiles, id: \.path) { file in
                            FileCard(
                                sessionId: key,
                                file: file,
                                // Basket keyed by the PR key; scope each card to its own
                                // file (the PR diff has no commit source, so sha is nil).
                                comments: model.comments(key).filter {
                                    $0.file == file.path && $0.commitSha == nil
                                },
                                // A file with a live content match auto-expands so its
                                // highlighted lines show without a manual click.
                                collapsed: !expandedPaths.contains(file.path)
                                    && !matches.contains(file.path),
                                selected: file.path == selectedPath,
                                onToggleCollapse: { toggle(file.path) },
                                viewable: false,
                                editable: false,
                                contentMatch: contentQ)
                                .id(file.path)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selectedPath) { _, path in
                    guard let path else { return }
                    expandedPaths.insert(path)
                    withAnimation { proxy.scrollTo(path, anchor: .top) }
                }
            }
        }
    }

    /// The staged-notes bar: a count, Discard, and Send to agent (queues the whole
    /// batch on the tracking session, or tracks-and-queues an untracked PR). Shown
    /// only while notes are staged; flashes a confirmation briefly after a hand-off.
    @ViewBuilder
    private var reviewBar: some View {
        let staged = model.comments(key)
        if model.github.queuedFlash.contains(key) {
            HStack(spacing: 6) {
                Label("Sent to agent", systemImage: "checkmark")
                    .font(.system(size: 11)).foregroundStyle(.green)
                Spacer()
            }
            .padding(.top, 4)
        } else if !staged.isEmpty {
            HStack(spacing: 8) {
                Text("\(staged.count) comment\(staged.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Discard") { model.discardComments(key) }
                    .controlSize(.small)
                    .clickCursor()
                Button("Send to agent") {
                    model.github.sendDiffReview(appModel: model, cwd: cwd, pr: pr)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help(model.trackedPr(cwd: cwd, number: pr.number) != nil
                      ? "Queue these notes on the PR's tracking session (delivered on its next idle)"
                      : "Track this PR and queue these notes on its new agent session")
                .clickCursor()
            }
            .padding(.top, 4)
        }
    }

    private func toggle(_ path: String) {
        if expandedPaths.contains(path) { expandedPaths.remove(path) } else { expandedPaths.insert(path) }
    }

    private func leading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A relative date string for a comment/review timestamp ("2 hr ago"), empty
/// when the timestamp didn't parse.
private func relativeDate(_ d: Date?) -> String {
    guard let d else { return "" }
    return relativeTime(Int(d.timeIntervalSince1970 * 1000))
}

/// The full detail pane for the selected PR: header + actions, needs-decision
/// notifications, CI checks (with failing logs inline), and the conversation —
/// review verdicts, issue comments, and inline review threads, each replyable
/// directly or hand-off-able to the tracking agent.
private struct GitHubPrDetail: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    @State private var descriptionExpanded = true
    /// Which detail tab is showing — the conversation timeline or the PR diff.
    @State private var tab: PrDetailTab = .conversation

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }
    private var conversation: PrConversation? { model.github.conversations[key] }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHead
            Divider()
            switch tab {
            case .conversation:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        notificationRows
                        descriptionDisclosure
                        checksSection
                        Divider()
                        conversationSection
                        if let err = model.github.actionError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .diff:
                // The diff tab owns its own tree/diff scroll views, so it must fill the
                // pane rather than sit inside the conversation's outer ScrollView.
                VStack(alignment: .leading, spacing: 0) {
                    if hasNotifications {
                        notificationRows.padding(.horizontal, 16).padding(.top, 12)
                    }
                    PrDiffTab(pr: pr, cwd: cwd)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var hasNotifications: Bool { !(tracked?.notifications.isEmpty ?? true) }

    /// The fixed top block: PR identity (title/branch/actions) plus the sticky
    /// Conversation/Diff switcher, on an opaque background so scrolled content
    /// never bleeds under it.
    private var pinnedHead: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $tab) {
                ForEach(PrDetailTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(pr.number)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if pr.draft {
                    Text("draft")
                        .font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let state = conversation?.state, !state.isEmpty {
                    PrStateChip(state: state)
                }
                if let t = tracked { TrackBadge(state: t.state) }
                Spacer()
            }
            HStack(spacing: 8) {
                Text(pr.branch)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text((cwd as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if !pr.author.isEmpty {
                    Text("by @\(pr.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 10) {
                GitHubPrActions(pr: pr, cwd: cwd)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
    }

    /// The PR's own description, as a collapsible block (expanded by default).
    /// Only shown once the conversation has loaded and the PR actually has a body.
    @ViewBuilder
    private var descriptionDisclosure: some View {
        if let body = conversation?.body,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup(isExpanded: $descriptionExpanded) {
                CommentMarkdown(text: body)
                    .padding(.top, 4)
            } label: {
                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .clickCursor()
            }
            .padding(.top, 2)
        }
    }

    // MARK: needs-decision notifications

    @ViewBuilder
    private var notificationRows: some View {
        if let t = tracked, !t.notifications.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(t.notifications) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.message)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                            Text(relativeTime(n.createdAt))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Dismiss") {
                            model.resolveNotification(prId: t.id, notificationId: n.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .clickCursor()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: checks

    @ViewBuilder
    private var checksSection: some View {
        if let runs = model.github.checks[key], !runs.isEmpty {
            GitHubChecksSection(pr: pr, cwd: cwd, runs: runs)
        }
    }

    // MARK: conversation

    @ViewBuilder
    private var conversationSection: some View {
        if let convo = conversation {
            GitHubConversationSection(pr: pr, cwd: cwd, conversation: convo)
        } else if model.github.loading.contains(key) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Text("Couldn't load conversation")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("Retry") { model.github.loadDetail(cwd: cwd, pr: pr) }
                    .controlSize(.small)
                    .clickCursor()
            }
        }
    }
}

/// OPEN / CLOSED / MERGED chip for the detail header, GitHub-colored.
private struct PrStateChip: View {
    let state: String

    var body: some View {
        Text(state.lowercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var color: Color {
        switch state {
        case "OPEN": return .green
        case "MERGED": return .purple
        case "CLOSED": return .red
        default: return .secondary
        }
    }
}

/// The CI checks list: one row per check run (outcome icon, name, state,
/// link-out), plus a shared failing-logs disclosure — `gh` fetches the failing
/// steps for the whole PR at once, so every failing row toggles the same block.
private struct GitHubChecksSection: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    let runs: [PrCheckRun]
    @State private var showLogs = false

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }

    private var hasFailing: Bool { runs.contains(where: \.failed) }
    private var isRerunning: Bool { model.github.rerunning.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Checks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isRerunning { ProgressView().controlSize(.mini) }
                if hasFailing {
                    Button("Re-run failed") {
                        model.github.rerunChecks(cwd: cwd, pr: pr, failedOnly: true)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .disabled(isRerunning)
                    .help("gh run rerun --failed: re-run only the failed jobs")
                    .clickCursor()
                }
                Button("Re-run all") {
                    model.github.rerunChecks(cwd: cwd, pr: pr, failedOnly: false)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .disabled(isRerunning)
                .help("gh run rerun: re-run every job on this PR")
                .clickCursor()
            }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                checkRow(run)
            }
            logsBlock
        }
    }

    private func checkRow(_ run: PrCheckRun) -> some View {
        let outcome = checkOutcome(run)
        return HStack(spacing: 6) {
            Image(systemName: icon(outcome))
                .font(.system(size: 10))
                .foregroundStyle(color(outcome))
            Text(run.name.isEmpty ? "(unnamed check)" : run.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .help(run.name)
            Text(run.state.lowercased())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if run.failed {
                Button(showLogs ? "Hide logs" : "Show logs") {
                    showLogs.toggle()
                    if showLogs { model.github.loadCiLogs(cwd: cwd, pr: pr) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .clickCursor()
            }
            if !run.link.isEmpty {
                Button {
                    if let url = URL(string: run.link) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Open the check on GitHub")
                .clickCursor()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var logsBlock: some View {
        if showLogs {
            if model.github.ciLogsLoading.contains(key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching failing-step logs…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let logs = model.github.ciLogs[key] {
                ScrollView {
                    Text(logs)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(6)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func icon(_ o: PrCheckOutcome) -> String {
        switch o {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ o: PrCheckOutcome) -> Color {
        switch o {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .orange
        case .skipped: return .secondary
        }
    }
}

/// The conversation, GitHub-Conversation-tab style: one chronological timeline
/// of contained cards — issue comments, review events (verdict + summary + the
/// inline file comments submitted with them), and commits interleaved by time —
/// closed off with a persistent comment composer pinned at the end.
private struct GitHubConversationSection: View {
    let pr: PullRequest
    let cwd: String
    let conversation: PrConversation
    /// The persistent bottom composer is always mounted; this binding satisfies
    /// `ReplyComposer` without ever collapsing it (Cancel is hidden in that mode).
    @State private var composerOpen = true

    var body: some View {
        let timeline = prTimeline(conversation)
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if timeline.isEmpty {
                Text("No comments yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(timeline) { item in
                switch item {
                case .review(let review):
                    ReviewEventRow(pr: pr, cwd: cwd, review: review, conversation: conversation)
                case .comment(let comment):
                    IssueCommentRow(pr: pr, cwd: cwd, comment: comment)
                case .commit(let commit):
                    CommitRow(commit: commit, prUrl: pr.url)
                }
            }
            Divider().opacity(0.4).padding(.top, 2)
            Text("Add a comment")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ReplyComposer(pr: pr, cwd: cwd, replyTargetId: nil,
                          isPresented: $composerOpen, persistent: true)
        }
    }
}

/// The card chrome every conversation entry sits in: padded, panel-tinted, and
/// bordered, so each comment/review reads as a discrete unit (juancode-bkj).
private struct ConversationCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appPanel.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15)))
    }
}

/// A compact row of emoji-reaction chips (emoji + count) under a comment/review,
/// mirroring GitHub's reaction bar. Renders nothing when there are no reactions.
private struct ReactionsRow: View {
    let reactions: [PrReaction]

    var body: some View {
        let shown = reactions.filter { !$0.emoji.isEmpty }
        if !shown.isEmpty {
            HStack(spacing: 4) {
                ForEach(shown) { r in
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 11))
                        Text("\(r.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.top, 1)
        }
    }
}

/// One commit, interleaved chronologically in the timeline: a commit-node dot, a
/// clickable short SHA (opens the commit on GitHub), the headline, and the
/// author + time. Kept slim — not a full card — so commits read as lightweight
/// events between the comment cards.
private struct CommitRow: View {
    let commit: PrCommit
    let prUrl: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                if let u = commitURL { NSWorkspace.shared.open(u) }
            } label: {
                Text(commit.abbreviatedOid)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(commitURL == nil ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(commitURL == nil)
            .clickCursor()
            .help("Open commit on GitHub")
            Text(commit.messageHeadline)
                .font(.system(size: 11))
                .lineLimit(1)
                .help(commit.messageHeadline)
            Spacer(minLength: 4)
            if !commit.author.isEmpty {
                Text(commit.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(relativeDate(commit.committedDate))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 2)
    }

    /// `…/commit/<oid>`, derived from the PR url (`…/pull/<n>`); nil if the url
    /// doesn't look like a PR url.
    private var commitURL: URL? {
        guard let r = prUrl.range(of: "/pull/") else { return nil }
        return URL(string: "\(prUrl[..<r.lowerBound])/commit/\(commit.oid)")
    }
}

/// Renders a GitHub comment/review body. Markdown runs go through MarkdownUI
/// (headings, task lists, code, links) sized to the compact panel typography;
/// the `<details>`/`<summary>` blocks GitHub bots emit become native collapsible
/// disclosures instead of rendering their tags literally, and inline HTML
/// (`<strong>`, lists, tables, …) is converted to markdown in `parseCommentSegments`.
private struct CommentMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseCommentSegments(text).enumerated()), id: \.offset) { _, seg in
                CommentSegmentView(segment: seg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentSegmentView: View {
    let segment: CommentSegment

    var body: some View {
        switch segment {
        case .markdown(let md):
            Markdown(md)
                .markdownTheme(.prPanel)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .details(let summary, let inner):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, seg in
                        CommentSegmentView(segment: seg)
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Markdown(summary)
                    .markdownTheme(.prPanel)
            }
        }
    }
}

extension Theme {
    /// GitHub look at the panel's compact size: override only the base text
    /// size, letting the `.gitHub` theme's relative heading/code/quote sizes
    /// scale down with it.
    @MainActor
    static let prPanel: Theme = Theme.gitHub
        .text { FontSize(12) }
}

/// COMMENTED chip + relative time, and the review body when non-empty.
/// A small circular avatar for a comment/review author, loaded from GitHub's
/// CDN with a person-icon fallback while it loads or if the URL is missing/fails.
private struct CommentAvatar: View {
    let url: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.tertiary)
    }
}

/// One review event, the way GitHub's Conversation tab groups it: the reviewer +
/// verdict chip + time header, the review's summary body, then the inline file
/// comments it carried nested beneath — each with its `path:line`,
/// resolved/outdated badge, and its own Reply / Send-to-agent actions. A bare
/// verdict (approve with no notes) is just the header.
private struct ReviewEventRow: View {
    let pr: PullRequest
    let cwd: String
    let review: PrReviewItem
    let conversation: PrConversation

    var body: some View {
        ConversationCard {
            HStack(spacing: 6) {
                CommentAvatar(url: review.authorAvatarUrl)
                Text(review.author.isEmpty ? "(unknown)" : "@\(review.author)")
                    .font(.system(size: 11, weight: .semibold))
                Text(verdictText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chipColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(chipColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if review.comments.count > 1 {
                    Text("\(review.comments.count) comments")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(relativeDate(review.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            if !review.body.isEmpty {
                CommentMarkdown(text: review.body)
            }
            ReactionsRow(reactions: review.reactions)
            if !review.comments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review.comments) { c in
                        InlineReviewCommentRow(
                            pr: pr, cwd: cwd, comment: c,
                            info: conversation.threadInfo(forCommentId: c.id))
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2)
                }
            }
        }
    }

    /// "commented" reads oddly for a review with only inline notes; call it
    /// "reviewed" then, and keep the explicit approve/changes verdicts.
    private var verdictText: String {
        switch review.state {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "COMMENTED" where review.body.isEmpty: return "reviewed"
        default: return review.state.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    private var chipColor: Color {
        switch review.state {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        default: return .secondary
        }
    }
}

/// One inline file comment inside a review event: `path:line` header with
/// resolved/outdated badge, author + time, body, and Reply (targets its thread's
/// top-level comment — GitHub's replies API only accepts those) + Send-to-agent.
private struct InlineReviewCommentRow: View {
    let pr: PullRequest
    let cwd: String
    let comment: PrConversationComment
    let info: PrConversation.CommentThreadInfo?
    @State private var replying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let path = comment.path, !path.isEmpty {
                    Text(comment.line.map { "\(path):\($0)" } ?? path)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(path)
                }
                if info?.isResolved == true {
                    Text("resolved").font(.system(size: 9)).foregroundStyle(.green)
                }
                if info?.isOutdated == true {
                    Text("outdated").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if info?.replyTargetId != nil {
                    Button("Reply") { replying.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .clickCursor()
                }
                SendToAgentControl(
                    pr: pr, cwd: cwd, itemId: comment.id,
                    prompt: commentTaskPrompt(
                        number: pr.number, path: comment.path, line: comment.line,
                        author: comment.author, body: comment.body, url: comment.url))
            }
            HStack(spacing: 6) {
                CommentAvatar(url: comment.authorAvatarUrl, size: 14)
                Text(comment.author.isEmpty ? "(unknown)" : "@\(comment.author)")
                    .font(.system(size: 10, weight: .semibold))
                Text(relativeDate(comment.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            CommentMarkdown(text: comment.body)
            ReactionsRow(reactions: comment.reactions)
            if replying {
                ReplyComposer(pr: pr, cwd: cwd,
                              replyTargetId: info?.replyTargetId, isPresented: $replying)
            }
        }
    }
}

/// One issue-level comment card: author + time header, selectable body, and the
/// Reply / Send-to-agent actions (reply posts a top-level PR comment — issue
/// comments aren't threaded on GitHub).
private struct IssueCommentRow: View {
    let pr: PullRequest
    let cwd: String
    let comment: PrConversationComment
    @State private var replying = false

    var body: some View {
        ConversationCard {
            HStack(spacing: 6) {
                CommentAvatar(url: comment.authorAvatarUrl)
                Text(comment.author.isEmpty ? "(unknown)" : "@\(comment.author)")
                    .font(.system(size: 11, weight: .semibold))
                Text(relativeDate(comment.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button("Reply") { replying.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .clickCursor()
                SendToAgentControl(
                    pr: pr, cwd: cwd, itemId: comment.id,
                    prompt: commentTaskPrompt(
                        number: pr.number, path: nil, line: nil,
                        author: comment.author, body: comment.body, url: comment.url))
            }
            CommentMarkdown(text: comment.body)
            ReactionsRow(reactions: comment.reactions)
            if replying {
                ReplyComposer(pr: pr, cwd: cwd, replyTargetId: nil, isPresented: $replying)
            }
        }
    }
}

/// The "Send to agent" affordance next to a comment/thread. Tracked PR → one
/// button that queues the prompt on the tracking session (flashing "Queued");
/// untracked → a menu offering Track & send (spawn the tracking session, then
/// queue) or Work on PR (fresh review session).
private struct SendToAgentControl: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    let itemId: String
    let prompt: String

    var body: some View {
        if model.github.queuedFlash.contains(itemId) {
            Label("Queued", systemImage: "checkmark")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        } else if model.trackedPr(cwd: cwd, number: pr.number) != nil {
            Button("Send to agent") {
                model.github.sendToAgent(appModel: model, cwd: cwd, pr: pr,
                                         prompt: prompt, itemId: itemId)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .help("Queue this comment on the PR's tracking session (delivered on its next idle)")
            .clickCursor()
        } else {
            Menu("Send to agent") {
                Button("Track & send") {
                    model.github.trackAndSend(appModel: model, cwd: cwd, pr: pr,
                                              prompt: prompt, itemId: itemId)
                }
                Button("Work on PR") { model.workOnPr(pr, cwd: cwd) }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 10))
            .fixedSize()
            .help("This PR isn't tracked yet — track it and queue this comment, or spawn a fresh session on the PR")
        }
    }
}

/// Reply composer: TextEditor + Send/Cancel. Send posts via `gh` off-main
/// (top-level comment when `replyTargetId` is nil, review-thread reply
/// otherwise), disabled with a spinner while in flight; failures surface inline.
/// Inline (`persistent: false`): success clears + collapses. Persistent (the
/// pinned bottom composer): no Cancel, and success clears but stays open. Either
/// way the conversation refetches so the new comment appears.
private struct ReplyComposer: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    let replyTargetId: Int?
    @Binding var isPresented: Bool
    var persistent: Bool = false
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 54, maxHeight: 120)
                .padding(4)
                .background(Color.appPanel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Comment") { send() }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || trimmed.isEmpty)
                    .clickCursor()
                if sending { ProgressView().controlSize(.mini) }
                if !persistent {
                    Button("Cancel") { isPresented = false }
                        .controlSize(.small)
                        .disabled(sending)
                        .clickCursor()
                }
                Spacer()
            }
        }
        .padding(.top, 2)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let body = trimmed
        guard !body.isEmpty, !sending else { return }
        sending = true
        error = nil
        Task {
            let err = await model.github.postReply(
                cwd: cwd, pr: pr, replyTargetId: replyTargetId, body: body)
            sending = false
            if let err {
                error = err
            } else {
                text = ""
                // Inline composers collapse on success; the pinned bottom one
                // stays open, ready for the next comment.
                if !persistent { isPresented = false }
            }
        }
    }
}
