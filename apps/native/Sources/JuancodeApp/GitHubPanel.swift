import SwiftUI
import AppKit
import JuancodeClient
import JuancodeCore
import JuancodeDesktop
import JuancodeServices
import MarkdownUI

// PR details overlay the session content, which stays mounted underneath.
// The right rail owns the list; selecting a PR opens its conversation and checks.

/// Selection + per-PR caches for the GitHub view, owned by `AppModel` so they
/// survive the view being dismissed and re-opened. Keys are
/// `TrackedPr.key(cwd:number:)` ("<cwd>#<number>").
@MainActor
@Observable
final class GitHubModel {
    /// Set by "Open Diff"; the PR detail flips to its Diff tab and clears it.
    var detailWantsDiff = false
    /// The selected PR's key, or nil when nothing is selected.
    var selectedKey: String?
    /// Keep the clicked row even when it came from outside the folder list, or
    /// that list is refreshed while its detail is open.
    private(set) var selectedRow: PrNavRow?
    /// Fetched conversations per PR — merged into the chronology they are read in by
    /// the core, not here.
    private(set) var timelines: [String: PrTimeline] = [:]
    /// Fetched CI check runs per PR, each carrying the outcome its row draws.
    private(set) var checks: [String: [PrCheckRow]] = [:]
    /// The core's GitHub read surface, handed over by `AppModel` at boot. Nil on a core
    /// that does not advertise `github`, and then `readsUnavailable` says why.
    var reads: GitHubReads?
    /// Why this core cannot answer the PR reads, when it cannot — the sentence the
    /// detail pane shows in place of a retry it has no route for.
    var readsUnavailable: String?
    /// When each PR's detail last landed — the "updated …" stamp in the detail
    /// header, and the input to `prDetailRefreshDue`.
    private(set) var fetchedAt: [String: Date] = [:]
    /// PR keys the tracked-PR poller saw move since their last detail fetch, so an
    /// open pane refetches on its next tick instead of waiting out the interval.
    private(set) var pollerActivity: Set<String> = []
    /// Fetched PR diffs per PR, for the detail's Diff tab (fetched lazily the first
    /// time that tab is shown, then refreshed with the rest of the detail while the
    /// tab is on screen).
    private(set) var diffs: [String: DiffResult] = [:]
    /// PR keys with a diff fetch in flight, so the tab doesn't stampede `gh pr diff`.
    private(set) var diffLoading: Set<String> = []
    /// PR keys with a detail fetch in flight, so selection doesn't stampede.
    private(set) var loading: Set<String> = []
    /// Failing-step CI logs per PR (fetched once, on demand — "Show logs").
    private(set) var ciLogs: [String: ActionsLog] = [:]
    /// PR keys with a CI-log fetch in flight (spinner on the checks row).
    private(set) var ciLogsLoading: Set<String> = []
    /// PR keys with a `gh run rerun` in flight (disables the rerun buttons).
    private(set) var rerunning: Set<String> = []
    /// Timeline-item ids briefly flashing a "Queued" confirmation after a
    /// successful "Send to agent".
    private(set) var queuedFlash: Set<String> = []
    /// The last action failure to surface inline (send-to-agent/track errors).
    var actionError: String?
    /// The right panel's PR order when a row was opened, for j/k navigation.
    var navOrder: [PrNavRow] = []

    /// One navigable row: the PR plus the folder it belongs to.
    struct PrNavRow: Equatable, Identifiable {
        let cwd: String
        let pr: PullRequest
        var id: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    }

    /// Move the selection `by` rows through `navOrder` (j/k), clamped at both ends.
    /// With nothing selected it lands on the first row (or the last, moving up).
    func moveSelection(by delta: Int) {
        guard !navOrder.isEmpty else { return }
        guard let key = selectedKey, let i = navOrder.firstIndex(where: { $0.id == key }) else {
            select(delta < 0 ? navOrder[navOrder.count - 1] : navOrder[0])
            return
        }
        let next = min(max(0, i + delta), navOrder.count - 1)
        guard next != i else { return }
        select(navOrder[next])
    }

    /// Jump to the first / last visible row (g / G, matching the sidebar's vocabulary).
    func selectFirstRow() { if let r = navOrder.first { select(r) } }
    func selectLastRow() { if let r = navOrder.last { select(r) } }

    /// The selected row's (folder, PR) pair, for keyboard actions that act on it.
    var selectedNavRow: PrNavRow? {
        guard let key = selectedKey else { return nil }
        return navOrder.first { $0.id == key }
    }

    private func select(_ row: PrNavRow) { load(cwd: row.cwd, pr: row.pr) }

    /// Select a PR and prefetch its detail for a row click or session deep-link.
    func select(cwd: String, pr: PullRequest) {
        load(cwd: cwd, pr: pr)
    }

    /// Update selection and prefetch its detail.
    private func load(cwd: String, pr: PullRequest) {
        selectedRow = PrNavRow(cwd: cwd, pr: pr)
        selectedKey = TrackedPr.key(cwd: cwd, number: pr.number)
        loadDetail(cwd: cwd, pr: pr)
    }

    /// Fetch the PR's timeline + check runs off the core and publish back here.
    /// Coalesces per PR; a failed timeline fetch keeps any previously cached one.
    ///
    /// Both are HTTP reads against `juancoded` rather than `gh` calls made here: the
    /// merge into one chronology and the check outcomes are the core's answers, so the
    /// phone and this pane cannot draw two different versions of one PR. A core with no
    /// `github` capability has no route to ask, and the pane says so instead of
    /// spinning.
    func loadDetail(cwd: String, pr: PullRequest) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !loading.contains(key), let reads else { return }
        loading.insert(key)
        // This fetch answers whatever the poller flagged; a signal arriving while it
        // is in flight re-flags the key and the next tick picks it up.
        pollerActivity.remove(key)
        let number = pr.number
        let url = pr.url
        Task {
            async let timeline = reads.timeline(cwd: cwd, number: number, prUrl: url)
            async let runs = reads.checks(cwd: cwd, number: number)
            let (t, r) = await (timeline, runs)
            // nil is a read that failed; an empty list is a PR with no checks. Keeping
            // the last good answer through a failure is the difference between "CI has
            // not run" and "we could not ask", and only one of those is true.
            if let t { timelines[key] = t }
            if let r { checks[key] = r }
            fetchedAt[key] = Date()
            loading.remove(key)
        }
    }

    /// Note that the tracked-PR poller saw new activity on a PR (new comments /
    /// reviews / a CI status change). Called from `AppModel`'s tracked mirror; the
    /// open detail pane acts on it within a tick.
    func notePollerActivity(_ key: String) { pollerActivity.insert(key) }

    /// Refetch the selected PR's detail if what the pane is showing has gone stale
    /// (`prDetailRefreshDue`) — the tick the detail pane runs while it is on screen,
    /// so a PR left open keeps up with GitHub instead of freezing at first open.
    /// `includeDiff` refreshes the diff too, and is only true while the Diff tab is
    /// showing (nobody pays for a `gh pr diff` they aren't looking at).
    func refreshIfStale(cwd: String, pr: PullRequest, includeDiff: Bool, focused: Bool) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard prDetailRefreshDue(lastFetched: fetchedAt[key], now: Date(), focused: focused,
                                 pollerActivity: pollerActivity.contains(key)) else { return }
        loadDetail(cwd: cwd, pr: pr)
        if includeDiff { loadDiff(cwd: cwd, pr: pr, force: true) }
    }

    /// Refetch the selected PR's detail now, whatever its age — the header's manual
    /// refresh, and the "Retry" after a failed load.
    func reloadDetail(cwd: String, pr: PullRequest, includeDiff: Bool) {
        loadDetail(cwd: cwd, pr: pr)
        if includeDiff { loadDiff(cwd: cwd, pr: pr, force: true) }
    }

    /// Fetch the PR's net diff, split into the same per-file shape the working tree
    /// answers with, for the detail's Diff tab. Cached per PR and coalesced so
    /// re-opening the tab is instant. A failed fetch leaves the cache empty so the tab
    /// retries. `force` refetches over a cached diff (the freshness tick, a manual
    /// refresh); the old diff stays on screen until the new one lands, so the tab
    /// never blanks.
    func loadDiff(cwd: String, pr: PullRequest, force: Bool = false) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard force || diffs[key] == nil, !diffLoading.contains(key) else { return }
        guard let reads else { return }
        diffLoading.insert(key)
        let number = pr.number
        Task {
            if let result = try? await reads.prDiff(cwd: cwd, number: number) {
                diffs[key] = result
            }
            diffLoading.remove(key)
        }
    }

    /// Fetch the failing-step CI logs for a PR (once — cached until the app restarts;
    /// the checks row offers a reload), already parsed into steps and folds by the
    /// core (juancode-52e8.14.6).
    ///
    /// An empty log is stored as one rather than as a sentence: a green PR has no
    /// failing build, and the block draws "no failing steps" from the empty value.
    func loadCiLogs(cwd: String, pr: PullRequest, reads: GitHubReads?) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !ciLogsLoading.contains(key), let reads else { return }
        ciLogsLoading.insert(key)
        let number = pr.number
        Task {
            ciLogs[key] = await reads.actionsLog(cwd: cwd, number: number) ?? ActionsLog()
            ciLogsLoading.remove(key)
        }
    }

    /// Re-run a PR's CI checks (`failedOnly` → "Re-run failed jobs", else "Re-run all
    /// jobs"). On success refetches the check runs so the row reflects the re-queued
    /// state, else surfaces the reason the core gave.
    func rerunChecks(cwd: String, pr: PullRequest, failedOnly: Bool) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard !rerunning.contains(key) else { return }
        guard let reads else {
            actionError = readsUnavailable
            return
        }
        rerunning.insert(key)
        actionError = nil
        let number = pr.number
        Task {
            do {
                try await reads.rerunChecks(cwd: cwd, number: number, failedOnly: failedOnly)
                loadDetail(cwd: cwd, pr: pr)
            } catch let e as GitHubError {
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
        guard let reads else { return readsUnavailable }
        do {
            try await reads.comment(cwd: cwd, number: pr.number, body: body,
                                    replyTo: replyTargetId)
            loadDetail(cwd: cwd, pr: pr)
            return nil
        } catch let e as GitHubError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }

    /// "Send to agent" on a tracked PR: queue the comment-task prompt on the
    /// tracking session via its message queue (idle-edge delivery, same as
    /// `submitReview`) and flash a transient confirmation on the item.
    ///
    /// The confirmation flashes only once the core has confirmed the queue write. It
    /// used to flash on the way past, which under the rust core meant a "Queued" badge
    /// over a message nothing had queued (juancode-rzl7).
    func sendToAgent(appModel: AppModel, cwd: String, pr: PullRequest, prompt: String, itemId: String) {
        guard let t = appModel.trackedPr(cwd: cwd, number: pr.number) else {
            actionError = "PR #\(pr.number) isn't tracked — use Track & send."
            return
        }
        Task {
            guard await appModel.queuePrompt(sessionId: t.sessionId, text: prompt) else {
                actionError = "Nothing was sent to the agent for PR #\(pr.number)."
                return
            }
            flashQueued(itemId)
        }
    }

    /// "Track & send" on an untracked PR: start tracking (spawns the seeded
    /// agent session), then queue the prompt on it.
    func trackAndSend(appModel: AppModel, cwd: String, pr: PullRequest, prompt: String, itemId: String) {
        Task {
            if await appModel.trackPrAndQueue(pr, cwd: cwd, prompt: prompt) {
                flashQueued(itemId)
            } else {
                // Either the spawn or the queue write; `errorMessage` carries which, so
                // this does not claim one of them.
                actionError = "Couldn't hand PR #\(pr.number) to an agent — nothing was sent."
            }
        }
    }

    /// Resolve (or reopen) an inline review thread, then refetch the conversation so
    /// the thread redraws in its new state. Returns the error to surface, or nil.
    func setThreadResolved(cwd: String, pr: PullRequest, threadId: String, resolved: Bool) async -> String? {
        guard let reads else { return readsUnavailable ?? "This core cannot write to GitHub." }
        do {
            try await reads.resolveThread(cwd: cwd, threadId: threadId, resolved: resolved)
            loadDetail(cwd: cwd, pr: pr)
            return nil
        } catch let e as GitHubError {
            return e.message
        } catch {
            return error.localizedDescription
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
        // The basket is discarded only after the hand-off is confirmed, on both
        // branches. Discarding it first is how staged review notes used to disappear
        // into a queue write that never happened (juancode-rzl7).
        if let t = appModel.trackedPr(cwd: cwd, number: pr.number) {
            Task {
                guard await appModel.queuePrompt(sessionId: t.sessionId, text: prompt) else {
                    actionError = "Review not sent for PR #\(pr.number) — your notes are still staged."
                    return
                }
                appModel.discardComments(key)
                flashQueued(key)
            }
        } else {
            Task {
                if await appModel.trackPrAndQueue(pr, cwd: cwd, prompt: prompt) {
                    appModel.discardComments(key)
                    flashQueued(key)
                } else {
                    actionError = "Review not sent for PR #\(pr.number) — your notes are still staged."
                }
            }
        }
    }

    /// Show "Queued" next to the item for a moment, then clear it.
    private func flashQueued(_ itemId: String) {
        queuedFlash.insert(itemId)
        Task {
            await Nap.duration(.seconds(2.5))
            queuedFlash.remove(itemId)
        }
    }
}

/// Individual PR details. The right rail owns the PR list.
struct GitHubView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("GitHub", systemImage: "arrow.triangle.pull")
                    .font(.system(size: 14, weight: .semibold))
                if let (_, pr) = model.selectedGitHubPr {
                    Text(verbatim: "#\(pr.number)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let (cwd, pr) = model.selectedGitHubPr {
                        model.github.reloadDetail(cwd: cwd, pr: pr, includeDiff: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh PR details")
                Button { model.showingGitHub = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if let (cwd, pr) = model.selectedGitHubPr {
                GitHubPrDetail(pr: pr, cwd: cwd)
                    .id(TrackedPr.key(cwd: cwd, number: pr.number))
            } else {
                ContentUnavailableView {
                    Label("No pull request selected", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("Pick a PR in the right panel to see its conversation and checks.")
                } actions: {
                    Button("Show PR panel") { model.openViewerPrQueue() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appSurface)
        .onExitCommand { model.showingGitHub = false }
        .onChange(of: model.githubScope.flatMap { model.prs($0) }) { _, _ in
            model.resolvePendingBranchSelect()
        }
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
        Button { model.openPrDiffReview(pr, cwd: cwd) } label: {
            Label("Review Diff", systemImage: "text.bubble")
        }
            .help("Review the PR's diff against its base branch in the full-width review (⌘⇧D): comment on lines, send them to the PR's agent")
        if let t = tracked {
            // `selection`'s didSet closes the GitHub view.
            Button("Go to Session") { model.selection = t.sessionId }
            Button("Untrack") { model.untrackPr(t.id) }
                .disabled(!model.supports(.trackedPrs))
        } else {
            Button("Track") { model.trackPr(pr, cwd: cwd) }
                .disabled(!model.supports(.trackedPrs))
                .help(model.unavailable(.trackedPrs) ?? "Track this PR: an agent watches it and answers review comments")
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
            Button { model.openPrDiffReview(pr, cwd: cwd) } label: {
                Label("Review", systemImage: "text.bubble")
            }
            .controlSize(.small)
            .help("Open this diff in the full-width review (⌘⇧D): vim keys, line comments, sent to the PR's agent")
            .clickCursor()
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
    private var conversation: PrTimeline? { model.github.timelines[key] }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHead
            Divider()
            switch tab {
            case .conversation:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        notificationRows
                        descriptionDisclosure
                        checksSection
                        conversationSection
                        if let err = model.github.actionError {
                            Label(err, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(Color.appSurface)
            case .diff:
                VStack(alignment: .leading, spacing: 0) {
                    if hasNotifications {
                        notificationRows.padding(.horizontal, 20).padding(.top, 12)
                    }
                    PrDiffTab(pr: pr, cwd: cwd)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // Keep what's on screen honest (juancode-zp29): while this pane is up, tick
        // and refetch the PR once its data goes stale — on the interval, or as soon
        // as the tracked-PR poller reports the PR moved. Restarts on PR/tab change so
        // the loop's view of both stays current.
        .task(id: "\(key)|\(tab.rawValue)") { await freshnessTick() }
        .onChange(of: model.github.detailWantsDiff, initial: true) { _, wants in
            guard wants else { return }
            tab = .diff
            model.github.detailWantsDiff = false
        }
    }

    /// The freshness loop. Short tick, cheap body: the policy decides whether a fetch
    /// actually happens, so the interval and the focus backoff live in one place and
    /// regaining focus refreshes within a tick rather than at the next interval edge.
    private func freshnessTick() async {
        while !Task.isCancelled {
            model.github.refreshIfStale(cwd: cwd, pr: pr, includeDiff: tab == .diff,
                                        focused: NSApp.isActive)
            await Nap.duration(.seconds(5))
        }
    }

    private var hasNotifications: Bool { !(tracked?.notifications.isEmpty ?? true) }

    /// The fixed top block: PR identity (title/branch/actions) plus the sticky
    /// Conversation/Diff switcher, on an opaque background so scrolled content
    /// never bleeds under it.
    private var pinnedHead: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(spacing: 20) {
                ForEach(PrDetailTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item == .conversation ? "bubble.left.and.bubble.right" : "doc.text")
                            Text(item == .diff ? "Files changed" : item.label)
                            if item == .diff, let count = pr.changedFiles {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) {
                            if tab == item {
                                Capsule().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .clickCursor()
                }
                Spacer(minLength: 0)
                freshness.padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appPanel)
    }

    /// How old the data on screen is, plus a manual refresh.
    private var freshness: some View {
        PrFreshnessStamp(
            fetchedAt: model.github.fetchedAt[key],
            loading: model.github.loading.contains(key),
            refresh: { model.github.reloadDetail(cwd: cwd, pr: pr, includeDiff: tab == .diff) })
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                Text((cwd as NSString).lastPathComponent)
                Text("/")
                Text("Pull request #\(pr.number)")
                Spacer(minLength: 0)
                if let t = tracked { TrackBadge(state: t.state) }
                if let chain = model.chain(of: .trackedPr, ref: key) {
                    ChainBadge(chain: chain, member: ChainMemberRef(kind: .trackedPr, ref: key))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Text(pr.title)
                .font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { identity; Spacer(minLength: 12); changeStats }
                VStack(alignment: .leading, spacing: 10) { identity; changeStats }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            if let state = conversation?.state, state == "MERGED" || state == "CLOSED" {
                PrStateChip(state: state)
            } else if pr.draft {
                detailBadge("Draft", icon: "pencil", color: .secondary)
            } else if conversation?.state == "OPEN" {
                detailBadge("Open", icon: "arrow.triangle.pull", color: .green)
            }
            if !pr.author.isEmpty {
                Text("@\(pr.author)").fontWeight(.medium)
            }
            Text(pr.branch)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .help(pr.branch)
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
    }

    @ViewBuilder private var changeStats: some View {
        if let counts = pr.diffCounts {
            DiffStatLabel(counts: counts, size: 11).fixedSize()
        }
    }

    @ViewBuilder private var actions: some View {
        GitHubPrActions(pr: pr, cwd: cwd)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11))
    }

    private func detailBadge(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder private var descriptionDisclosure: some View {
        if let conversation {
            PrDetailCard {
                DisclosureGroup(isExpanded: $descriptionExpanded) {
                    if conversation.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description provided.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.top, 10)
                    } else {
                        CommentMarkdown(text: conversation.body).padding(.top, 12)
                    }
                } label: {
                    Label("Description", systemImage: "text.alignleft")
                        .font(.system(size: 12, weight: .semibold))
                }
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
            GitHubConversationSection(pr: pr, cwd: cwd, timeline: convo)
        } else if model.github.loading.contains(key) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let reason = model.github.readsUnavailable {
            // No route to ask, so no Retry: a button that re-runs a read this core has
            // no capability for is a button that can only fail the same way twice.
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            HStack(spacing: 8) {
                Text("Couldn't load conversation")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("Retry") { model.github.reloadDetail(cwd: cwd, pr: pr, includeDiff: false) }
                    .controlSize(.small)
                    .clickCursor()
            }
        }
    }
}

/// The selected PR's "updated 2 min ago" stamp + manual refresh (juancode-zp29).
/// Owns its own clock so re-labelling the age doesn't re-render the whole detail
/// pane, and shows a spinner while a refresh (auto or manual) is in flight.
private struct PrFreshnessStamp: View {
    let fetchedAt: Date?
    let loading: Bool
    let refresh: () -> Void
    /// Re-read on a slow tick purely to advance the label.
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 5) {
            if loading {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("The PR refreshes on its own while this pane is open — slower when juancode isn't frontmost")
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Refresh this PR now")
            .clickCursor()
        }
        .task {
            while !Task.isCancelled {
                await Nap.duration(.seconds(15))
                now = Date()
            }
        }
    }

    private var label: String {
        guard let fetchedAt else { return loading ? "loading…" : "not loaded" }
        // `now` only exists to invalidate this label; the string itself is relative
        // to the real current time.
        _ = now
        return "updated \(relativeTime(Int(fetchedAt.timeIntervalSince1970 * 1000)))"
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
/// link-out), plus a shared failing-logs disclosure. The collapsed summary keeps
/// failures visible; logs are explicitly PR-wide because gh returns them together.
private struct GitHubChecksSection: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    let runs: [PrCheckRow]
    @State private var showLogs = false

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }

    private var hasFailing: Bool { runs.contains(where: \.failed) }
    private var isRerunning: Bool { model.github.rerunning.contains(key) }

    @State private var expanded = false

    private var failedCount: Int { runs.filter { $0.outcome == .fail }.count }
    private var pendingCount: Int { runs.filter { $0.outcome == .pending }.count }
    private var passedCount: Int { runs.filter { $0.outcome == .pass }.count }
    private var skippedCount: Int { runs.filter { $0.outcome == .skipped }.count }

    var body: some View {
        PrDetailCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    HStack(spacing: 10) {
                        Text("\(runs.count) checks").foregroundStyle(.secondary)
                        Spacer()
                        if isRerunning { ProgressView().controlSize(.mini) }
                        if hasFailing {
                            Button("Re-run failed") {
                                model.github.rerunChecks(cwd: cwd, pr: pr, failedOnly: true)
                            }
                            .disabled(isRerunning)
                        }
                        Button("Re-run all") {
                            model.github.rerunChecks(cwd: cwd, pr: pr, failedOnly: false)
                        }
                        .disabled(isRerunning)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        checkRow(run)
                    }
                    if hasFailing {
                        Button(showLogs ? "Hide failing-step logs" : "Show failing-step logs") {
                            showLogs.toggle()
                            if showLogs { model.github.loadCiLogs(cwd: cwd, pr: pr, reads: model.core.github) }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                    }
                    logsBlock
                }
                .padding(.top, 10)
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Label("Checks", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        summary
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Checks").font(.system(size: 12, weight: .semibold))
                        summary
                    }
                }
            }
        }
        .onAppear { expanded = hasFailing }
        .onChange(of: hasFailing) { _, failing in
            if failing { expanded = true }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if failedCount > 0 { summaryCount(failedCount, "failed", .fail) }
            if pendingCount > 0 { summaryCount(pendingCount, "pending", .pending) }
            if passedCount > 0 { summaryCount(passedCount, "passed", .pass) }
            if skippedCount > 0 { summaryCount(skippedCount, "skipped", .skipped) }
        }
        .font(.system(size: 11))
    }

    private func summaryCount(_ count: Int, _ title: String, _ outcome: PrCheckOutcome) -> some View {
        Label("\(count) \(title)", systemImage: icon(outcome))
            .foregroundStyle(color(outcome))
            .fixedSize()
    }

    private func checkRow(_ run: PrCheckRow) -> some View {
        let outcome = run.outcome
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
            } else if let log = model.github.ciLogs[key] {
                ActionsLogView(log: log)
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
    /// Already merged, already filtered: a review that carried nothing but replies to
    /// an existing thread has no item of its own, because its replies show inside that
    /// thread. That is the core's call, not this view's.
    let timeline: PrTimeline
    /// The persistent bottom composer is always mounted; this binding satisfies
    /// `ReplyComposer` without ever collapsing it (Cancel is hidden in that mode).
    @State private var composerOpen = true

    @State private var filter: PrConversationFilter = .all

    private var visibleItems: [PrTimelineItem] { filter.apply(to: timeline.items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conversation")
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PrConversationFilter.allCases, id: \.self) { option in
                        Button { filter = option } label: {
                            HStack(spacing: 5) {
                                Text(option.label)
                                Text("\(option.count(in: timeline.items))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: filter == option ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(filter == option ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(filter == option ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == option ? .isSelected : [])
                        .help(option == .unresolved ? "Show unresolved review threads, including outdated threads" : "Show \(option.label.lowercased()) activity")
                        .clickCursor()
                    }
                }
            }
            if visibleItems.isEmpty {
                Text(filter == .all ? "No conversation yet. Start one below." :
                        filter == .unresolved ? "No unresolved review threads in this conversation." :
                        "No \(filter.label.lowercased()) yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            }
            ForEach(visibleItems) { item in
                switch item {
                case .review(let review, let groups, _, _):
                    ReviewEventRow(pr: pr, cwd: cwd, review: review, threadGroups: groups)
                case .comment(let comment, _, _):
                    IssueCommentRow(pr: pr, cwd: cwd, comment: comment)
                case .commit(let commit, _, _):
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
///
/// Fill and border both sit well above the old half-opacity panel tint: against
/// the panel's near-black background a card at 0.5/0.15 was effectively invisible,
/// so a long thread read as one undifferentiated wall of text.
private struct PrDetailCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appPanel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18)))
    }
}

private struct ConversationCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        PrDetailCard { content }
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
            Text(relativeDate(commit.committed))
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
struct CommentMarkdown: View {
    let text: String

    var body: some View {
        // A review bot's P1/P2 badge is a remote image the panel never draws, so it
        // is parsed out of the body and drawn as a chip — the severity is the first
        // thing you need off a finding.
        let (priority, body) = extractCommentPriority(text)
        VStack(alignment: .leading, spacing: 6) {
            if let priority {
                PriorityChip(priority: priority)
            }
            ForEach(Array(parseCommentSegments(body).enumerated()), id: \.offset) { _, seg in
                CommentSegmentView(segment: seg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A review finding's severity as a native chip ("P1", "P2", …), coloured from the
/// badge url's shields.io colour word and falling back to a sensible ramp by
/// number when the url doesn't carry one.
private struct PriorityChip: View {
    let priority: CommentPriority

    var body: some View {
        Text(priority.label)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.45)))
            .help("Reviewer-assigned priority \(priority.label)")
    }

    private var color: Color {
        switch priority.colorName {
        case "red", "brightred", "critical": return .red
        case "orange": return .orange
        case "yellow", "important": return .yellow
        case "blue", "informational": return .blue
        case "green", "brightgreen", "success": return .green
        case "grey", "gray", "lightgrey", "lightgray": return .secondary
        default: break
        }
        // No colour word in the url: P1 loudest, then down the ramp.
        switch priority.label.dropFirst() {
        case "1": return .red
        case "2": return .yellow
        case "3": return .blue
        default: return .secondary
        }
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
    /// The threads this review *started*, as the core grouped them — a comment that
    /// only replies to an earlier review's thread is not one of these; it is already on
    /// screen inside that thread.
    let threadGroups: [PrThreadGroup]

    var body: some View {
        ConversationCard {
            HStack(spacing: 6) {
                CommentAvatar(url: review.authorAvatarUrl)
                Text(review.author.isEmpty ? "(unknown)" : "@\(review.author)")
                    .font(.system(size: 11, weight: .semibold))
                Text(verdictText)
                    .font(.system(size: 9, weight: .medium))
                    // A grey chip label on a grey chip fill on a near-black card was
                    // three shades of the same nothing; the neutral verdict borrows
                    // the card's text colour instead.
                    .foregroundStyle(chipColor == .secondary ? Color.primary.opacity(0.8) : chipColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(chipColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(chipColor.opacity(0.35)))
                if !threadGroups.isEmpty {
                    Text("\(threadGroups.count) thread\(threadGroups.count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(relativeDate(review.created))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if !review.body.isEmpty {
                CommentMarkdown(text: review.body)
            }
            ReactionsRow(reactions: review.reactions)
            if !threadGroups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(threadGroups) { group in
                        ReviewThreadRow(pr: pr, cwd: cwd, group: group)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
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

/// One inline review *thread* inside a review event: the `path:line` header with
/// resolved/outdated badges, the diff hunk once, then every comment in the thread
/// — the root finding followed by the replies, indented under a rule so a
/// back-and-forth reads as one conversation. Reply targets the thread's top-level
/// comment (GitHub's replies API only accepts those).
private struct ReviewThreadRow: View {
    let pr: PullRequest
    let cwd: String
    let group: PrThreadGroup
    @State private var replying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if let root = group.root {
                if let hunk = root.diffHunk, !hunk.isEmpty {
                    ReviewHunkView(diffHunk: hunk, path: group.path ?? "")
                }
                commentBlock(root, avatarSize: 14)
            }
            if !group.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.replies) { reply in
                        commentBlock(reply, avatarSize: 13)
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1)
                }
            }
            if replying {
                ReplyComposer(pr: pr, cwd: cwd,
                              replyTargetId: group.replyTargetId, isPresented: $replying)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let path = group.path, !path.isEmpty {
                Text(group.line.map { "\(path):\($0)" } ?? path)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
            if group.isResolved { stateChip("resolved", .green) }
            if group.isOutdated { stateChip("outdated", .secondary) }
            if group.replies.count > 0 {
                stateChip("\(group.replies.count) \(group.replies.count == 1 ? "reply" : "replies")",
                          .secondary)
            }
            Spacer(minLength: 4)
            if group.replyTargetId != nil {
                Button("Reply") { replying.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .clickCursor()
            }
            if let root = group.root {
                SendToAgentControl(
                    pr: pr, cwd: cwd, itemId: root.id,
                    prompt: commentTaskPrompt(
                        number: pr.number, path: root.path, line: root.line,
                        author: root.author, body: root.body, url: root.url,
                        diffHunk: root.diffHunk))
            }
        }
    }

    /// A bordered chip, not bare grey text: at 9pt on the panel's near-black
    /// background the plain labels were barely there.
    private func stateChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color == .secondary ? Color.primary.opacity(0.7) : color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.3)))
    }

    private func commentBlock(_ c: PrConversationComment, avatarSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                CommentAvatar(url: c.authorAvatarUrl, size: avatarSize)
                Text(c.author.isEmpty ? "(unknown)" : "@\(c.author)")
                    .font(.system(size: 10, weight: .semibold))
                Text(relativeDate(c.created))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            CommentMarkdown(text: c.body)
            ReactionsRow(reactions: c.reactions)
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
                Text(relativeDate(comment.created))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
