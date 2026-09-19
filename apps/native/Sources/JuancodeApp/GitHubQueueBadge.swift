// The toolbar's GitHub badge: how many PRs are on your plate, and the queue itself
// behind a click.
//
// It was a row in the Tools menu, counting the same queue and opening the same view
// two clicks deep. But "what is waiting on me on GitHub" is asked as often as "what
// is running", and both answers are a number you want without opening anything — so
// it takes a slot of its own beside the running badge, and the list comes with it.
//
// The popover is the queue, not a shortcut to it: the four filters are the four
// questions (everything, the ones I wrote, the ones I owe a review, the ones that
// actually want something today), a row opens the PR where it lives, and the full
// view is one click at the bottom for the things a popover can't do — diff, threads,
// send to agent.

import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

struct GitHubQueueBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    /// The chip that was on last time. Persisted: which half of the queue you live
    /// in is a habit, not a per-launch decision.
    @AppStorage("github.queue.filter") private var filterRaw = ViewerPrSlice.all.rawValue

    private var filter: ViewerPrSlice { ViewerPrSlice(rawValue: filterRaw) ?? .all }

    private var queue: ViewerPrResult { model.viewerPrs }
    private var needsYou: Int { model.viewerPrsNeedingYouCount }

    /// The badge counts the whole queue — the number is "how much is on my plate",
    /// and the tint is what says whether any of it is on fire. Filtering the count
    /// with the chip would make the toolbar lie whenever the chip wasn't "All".
    private var total: Int { model.viewerPrCount }

    var body: some View {
        Button {
            showing = true
            // Floored to one search a minute inside `refreshViewerPrs`, so opening
            // the popover repeatedly costs nothing.
            model.refreshViewerPrs()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                if queue.available, total > 0 {
                    Text("\(total)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .accessibilityLabel(badgeLabel)
        }
        .foregroundStyle(needsYou > 0 ? Color.orange : Color.primary)
        .help(badgeLabel)
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            GitHubQueuePopover(slice: Binding(get: { filter },
                                              set: { filterRaw = $0.rawValue }),
                               showing: $showing)
                .frame(width: 360)
        }
    }

    private var badgeLabel: String {
        guard queue.available else {
            return queue.error ?? "Your open PRs and the reviews you owe"
        }
        var parts = ["\(queue.mine.count) yours", "\(queue.reviewing.count) to review"]
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    /// The popover's content, as its own view.
    ///
    /// Not inlined into the button above: this body reads the queue, the viewer and
    /// every row's repo mapping, and a toolbar item is the one place in SwiftUI where
    /// that matters — see the note on `RootView` about what a re-render does to an
    /// open popover. Keeping it here means the churn lands on a child.
    private struct GitHubQueuePopover: View {
        @Environment(AppModel.self) private var model
        @Binding var slice: ViewerPrSlice
        @Binding var showing: Bool

        private var queue: ViewerPrResult { model.viewerPrs }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                chips
                Divider().padding(.vertical, 2)
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                QueueRow(row: row, reason: reason(row)) { open(row) }
                            }
                        }
                    }
                    // Tall enough for ~6 rows, then it scrolls: a popover that grows
                    // with a 40-PR queue runs off the screen.
                    .frame(maxHeight: 320)
                }
                Divider().padding(.vertical, 2)
                footer
            }
            .padding(.bottom, 6)
        }

        private var header: some View {
            HStack(spacing: 8) {
                Text("GitHub PRs").font(.system(size: 12, weight: .semibold))
                if model.viewerPrsLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
                Spacer(minLength: 8)
                if let at = model.viewerPrsFetchedAt {
                    Text(relativeTime(Int(at.timeIntervalSince1970 * 1000)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button { model.refreshViewerPrs(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Refresh your queue now (at most once a minute)")
                .clickCursor()
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
        }

        private var chips: some View {
            HStack(spacing: 4) {
                ForEach(ViewerPrSlice.allCases) { s in
                    let n = viewerPrCount(queue, slice: s)
                    Button { slice = s } label: {
                        HStack(spacing: 4) {
                            Text(label(s)).font(.system(size: 11, weight: .medium))
                            if n > 0 {
                                Text("\(n)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(s == .needsYou ? Color.orange : .secondary)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(slice == s ? Color.accentColor.opacity(0.22) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(s))
                    .clickCursor()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }

        private var footer: some View {
            Button {
                showing = false
                model.openViewerPrQueue()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.expand.vertical").font(.system(size: 10))
                    Text("Open the full view").font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    Text("⇧⌘G").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .help("The GitHub view: diff, threads, checks and send-to-agent")
        }

        /// The queue under the active chip, most urgent first (see `viewerPrRows`).
        private var rows: [ViewerPr] { viewerPrRows(queue, slice: slice) }

        private func reason(_ row: ViewerPr) -> PrAttentionReason? { row.attention }

        private func label(_ s: ViewerPrSlice) -> String {
            switch s {
            case .all: return "All"
            case .mine: return "Yours"
            case .review: return "To review"
            case .needsYou: return "Needs you"
            }
        }

        private func help(_ s: ViewerPrSlice) -> String {
            switch s {
            case .all: return "Every PR on your plate"
            case .mine: return "PRs you authored"
            case .review: return "PRs waiting on your review"
            case .needsYou: return "Red CI, changes requested, open threads, reviews you owe"
            }
        }

        private var emptyText: String {
            guard queue.available else { return queue.error ?? "Loading your queue…" }
            switch slice {
            case .all: return "Nothing on your plate — no open PRs of yours, no reviews waiting."
            case .mine: return "No open PRs of yours."
            case .review: return "No reviews waiting on you."
            case .needsYou: return "Nothing needs you — no red CI, no changes requested, no open threads."
            }
        }

        /// A row opens where the PR actually lives: in the GitHub view when juancode
        /// has that repo open (diff, threads, agent all reachable from there), on
        /// github.com when it doesn't — a review you owe on a repo you never cloned
        /// is still worth one click.
        private func open(_ row: ViewerPr) {
            showing = false
            if let cwd = model.folder(forRepo: row.repo) {
                model.github.select(cwd: cwd, pr: row.pr)
                model.openGitHub(scope: cwd)
            } else if let url = URL(string: row.pr.url) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// One PR in the popover: the check dot, the number and title, and a second line
    /// of why-it-matters (attention reason, checks, open threads, age). Narrower than
    /// the view's row, so the repo goes on the second line rather than a section
    /// header — the queue spans repos and a popover has no room for headers.
    private struct QueueRow: View {
        @Environment(AppModel.self) private var model
        let row: ViewerPr
        let reason: PrAttentionReason?
        let onOpen: () -> Void

        private var pr: PullRequest { row.pr }

        var body: some View {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(pr.checks.color).frame(width: 7, height: 7)
                        Text("#\(pr.number)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(pr.title).font(.system(size: 12)).lineLimit(1)
                        if pr.draft {
                            Text("draft")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Spacer(minLength: 4)
                    }
                    HStack(spacing: 6) {
                        if let reason {
                            Text(reason.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.16))
                                .clipShape(Capsule())
                        }
                        Text(row.repo).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Image(systemName: pr.checks.icon).font(.system(size: 9))
                            Text(pr.checksText).font(.system(size: 10).monospacedDigit())
                        }
                        .foregroundStyle(pr.checks.color)
                        if pr.unresolvedComments > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "bubble.left.fill").font(.system(size: 8))
                                Text("\(pr.unresolvedComments)").font(.system(size: 10))
                            }
                            .foregroundStyle(.orange)
                        }
                        if let age = prAgeLabel(pr.createdAt) {
                            Text(age).font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 13)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .help(helpText)
            .contextMenu {
                Button("Open on GitHub") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pr.url, forType: .string)
                }
            }
        }

        private var helpText: String {
            let where_ = model.folder(forRepo: row.repo) == nil
                ? "opens on github.com — no local checkout"
                : "opens in the GitHub view"
            return "\(row.repo) #\(pr.number) · \(where_)"
        }
    }
}
