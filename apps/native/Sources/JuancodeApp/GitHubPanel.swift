import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

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
    /// PR keys with a detail fetch in flight, so selection doesn't stampede.
    private(set) var loading: Set<String> = []
    /// Failing-step CI logs per PR (fetched once, on demand — "Show logs").
    private(set) var ciLogs: [String: String] = [:]
    /// PR keys with a CI-log fetch in flight (spinner on the checks row).
    private(set) var ciLogsLoading: Set<String> = []
    /// Timeline-item ids briefly flashing a "Queued" confirmation after a
    /// successful "Send to agent".
    private(set) var queuedFlash: Set<String> = []
    /// The last action failure to surface inline (send-to-agent/track errors).
    var actionError: String?

    /// Kick a PR-list refresh for every folder the view shows.
    func refresh(model: AppModel) {
        for cwd in model.githubFolders { model.loadPrs(cwd) }
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
            Button { model.github.refresh(model: model) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh open PRs for every folder")
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

    private var summary: String {
        let folders = model.githubFolders.count
        let prs = model.openPrTotal
        return "\(folders) folder\(folders == 1 ? "" : "s") · \(prs) open PR\(prs == 1 ? "" : "s")"
    }

    // MARK: PR list (left column)

    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.githubFolders, id: \.self) { cwd in
                    folderSection(cwd)
                }
                if model.githubFolders.isEmpty {
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
                    Text("\(r.prs.count)")
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
                    let ordered = sortPrsTrackedFirst(r.prs) {
                        model.trackedPr(cwd: cwd, number: $0.number) != nil
                    }
                    ForEach(ordered, id: \.number) { pr in
                        GitHubPrRow(pr: pr, cwd: cwd)
                        Divider()
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
        for cwd in model.githubFolders {
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

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }
    private var conversation: PrConversation? { model.github.conversations[key] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                notificationRows
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Checks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
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

/// The conversation: the merged issue-comment + review-verdict timeline
/// (chronological), then the inline review threads — unresolved expanded,
/// resolved/outdated collapsed behind a disclosure.
private struct GitHubConversationSection: View {
    let pr: PullRequest
    let cwd: String
    let conversation: PrConversation

    var body: some View {
        let timeline = prTimeline(conversation)
        let unresolved = conversation.threads.filter { !$0.isResolved && !$0.isOutdated }
        let settled = conversation.threads.filter { $0.isResolved || $0.isOutdated }
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if timeline.isEmpty && conversation.threads.isEmpty {
                Text("No comments yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(timeline) { item in
                switch item {
                case .review(let review):
                    ReviewVerdictRow(review: review)
                case .comment(let comment):
                    IssueCommentRow(pr: pr, cwd: cwd, comment: comment)
                }
            }
            if !unresolved.isEmpty || !settled.isEmpty {
                Text("Review threads")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(unresolved) { thread in
                    ReviewThreadView(pr: pr, cwd: cwd, thread: thread)
                }
                if !settled.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(settled) { thread in
                                ReviewThreadView(pr: pr, cwd: cwd, thread: thread)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("\(settled.count) resolved")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One review verdict in the timeline: author + APPROVED / CHANGES_REQUESTED /
/// COMMENTED chip + relative time, and the review body when non-empty.
private struct ReviewVerdictRow: View {
    let review: PrReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(review.author.isEmpty ? "(unknown)" : "@\(review.author)")
                    .font(.system(size: 11, weight: .semibold))
                Text(review.state.replacingOccurrences(of: "_", with: " ").lowercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chipColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(chipColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(relativeDate(review.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            if !review.body.isEmpty {
                Text(review.body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

/// One issue-level comment: author + time header, selectable body, and the
/// Reply / Send-to-agent actions (reply posts a top-level PR comment — issue
/// comments aren't threaded on GitHub).
private struct IssueCommentRow: View {
    let pr: PullRequest
    let cwd: String
    let comment: PrConversationComment
    @State private var replying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
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
            Text(comment.body)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if replying {
                ReplyComposer(pr: pr, cwd: cwd, replyTargetId: nil, isPresented: $replying)
            }
        }
    }
}

/// One inline review thread: a monospaced `path:line` header with
/// resolved/outdated badges, the comments slightly indented, and thread-level
/// Reply (targets the first comment's REST id — GitHub's replies API only
/// accepts top-level review comments) + Send-to-agent actions.
private struct ReviewThreadView: View {
    let pr: PullRequest
    let cwd: String
    let thread: PrReviewThread
    @State private var replying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(thread.path)
                if thread.isResolved {
                    Text("resolved")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
                if thread.isOutdated {
                    Text("outdated")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if thread.replyTargetId != nil {
                    Button("Reply") { replying.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .clickCursor()
                }
                if let anchor = thread.comments.first {
                    SendToAgentControl(
                        pr: pr, cwd: cwd, itemId: thread.id,
                        prompt: commentTaskPrompt(
                            number: pr.number, path: thread.path, line: thread.line,
                            author: anchor.author, body: anchor.body, url: anchor.url))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(thread.comments) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(c.author.isEmpty ? "(unknown)" : "@\(c.author)")
                                .font(.system(size: 10, weight: .semibold))
                            Text(relativeDate(c.createdAt))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Text(c.body)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if replying {
                    ReplyComposer(pr: pr, cwd: cwd,
                                  replyTargetId: thread.replyTargetId, isPresented: $replying)
                }
            }
            .padding(.leading, 12)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appPanel.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

/// Inline expandable reply composer: TextEditor + Send/Cancel. Send posts via
/// `gh` off-main (top-level comment when `replyTargetId` is nil, review-thread
/// reply otherwise), disabled with a spinner while in flight; failures surface
/// inline, success clears + collapses and the conversation refetches.
private struct ReplyComposer: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    let replyTargetId: Int?
    @Binding var isPresented: Bool
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
                Button("Send") { send() }
                    .controlSize(.small)
                    .disabled(sending || trimmed.isEmpty)
                    .clickCursor()
                if sending { ProgressView().controlSize(.mini) }
                Button("Cancel") { isPresented = false }
                    .controlSize(.small)
                    .disabled(sending)
                    .clickCursor()
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
                isPresented = false
            }
        }
    }
}
