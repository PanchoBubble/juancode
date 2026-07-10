import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

// The first-class GitHub view (juancode-2t6): overlays the detail area of the
// split view (never a sheet — the session content stays mounted underneath,
// juancode-073) listing every open PR grouped by project folder. Selecting a PR
// prefetches its conversation + checks; the detail pane itself is a placeholder
// until juancode-1au fills it in.

/// Selection + per-PR caches for the GitHub view, owned by `AppModel` so they
/// survive the view being dismissed and re-opened. Keys are
/// `TrackedPr.key(cwd:number:)` ("<cwd>#<number>"). Kept lean — juancode-1au
/// extends it with logs, replies, and send-to-agent.
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
    /// The last action failure to surface inline (reply/track errors — 1au).
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

    // MARK: detail (right column) — placeholder until juancode-1au

    @ViewBuilder
    private var detail: some View {
        if let (cwd, pr) = selectedPr {
            GitHubDetailPlaceholder(pr: pr, cwd: cwd)
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

/// Minimal detail header + actions for the selected PR. The real detail pane —
/// conversation threads, checks, failing logs, replies, send-to-agent — lands
/// in juancode-1au; this proves the selection + prefetch plumbing.
private struct GitHubDetailPlaceholder: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String

    private var key: String { TrackedPr.key(cwd: cwd, number: pr.number) }
    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("#\(pr.number)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                if pr.draft {
                    Text("draft")
                        .font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let t = tracked { TrackBadge(state: t.state) }
                Spacer()
            }
            HStack(spacing: 8) {
                Text(pr.branch)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
                Text((cwd as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                GitHubPrActions(pr: pr, cwd: cwd)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            Divider()
            if model.github.loading.contains(key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading conversation + checks…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if let convo = model.github.conversations[key] {
                let runs = model.github.checks[key] ?? []
                Text("\(convo.issueComments.count) comment\(convo.issueComments.count == 1 ? "" : "s") · \(convo.threads.count) review thread\(convo.threads.count == 1 ? "" : "s") · \(runs.count) check\(runs.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let err = model.github.actionError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Text("Full PR detail — conversation, checks, logs, replies — lands in juancode-1au.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
