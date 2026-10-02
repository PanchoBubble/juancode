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
// actually want something today), a row opens the PR where it lives, a hovered row
// offers the two things you do to a PR without reading it first (hand it to a watching
// agent, or open a fresh session on it), and the full view is one click at the bottom
// for the rest — diff, threads, per-comment send-to-agent.

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
    struct GitHubQueuePopover: View {
        @Environment(AppModel.self) private var model
        @Binding var slice: ViewerPrSlice
        @Binding var showing: Bool
        /// Nil lets the list fill its container (the right rail); the popover caps it.
        var listMaxHeight: CGFloat? = 320

        private var queue: ViewerPrResult { model.viewerPrs }

        /// Minimised repos, newline-joined. Persisted: a repo you fold away is one
        /// you don't want to see next launch either.
        @AppStorage("github.queue.collapsedRepos") private var collapsedRaw = ""
        private var collapsed: Set<String> {
            Set(collapsedRaw.split(separator: "\n").map(String.init))
        }
        private func toggle(_ repo: String) {
            var set = collapsed
            if set.contains(repo) { set.remove(repo) } else { set.insert(repo) }
            collapsedRaw = set.sorted().joined(separator: "\n")
        }

        /// The selected session's repo, as the queue names it (owner/name).
        private var currentRepo: String? {
            guard let id = model.selection,
                  let meta = model.sessions.first(where: { $0.id == id }) else { return nil }
            let root = model.repoRoot(forSession: meta)
            if let nwo = model.repoNwoByCwd[root],
               let hit = groups.first(where: { $0.repo.lowercased() == nwo.lowercased() }) {
                return hit.repo
            }
            return groups.first { model.folder(forRepo: $0.repo) == root }?.repo
        }

        /// Unfolds the session's repo and scrolls it into view. Unfolding writes the
        /// persisted set, so folding it again by hand sticks until the session changes.
        private func reveal(_ repo: String?, _ proxy: ScrollViewProxy) {
            guard let repo else { return }
            if collapsed.contains(repo) { toggle(repo) }
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(repo, anchor: .top) }
        }

        /// Watched = a tracking agent is on it. Orthogonal to the slice, so it's its
        /// own dropdown rather than a fifth slice.
        enum WatchFilter: String, CaseIterable, Identifiable {
            case any, watched, unwatched
            var id: String { rawValue }
        }
        @AppStorage("github.queue.watchFilter") private var watchRaw = WatchFilter.any.rawValue
        private var watch: WatchFilter { WatchFilter(rawValue: watchRaw) ?? .any }

        enum SortOrder: String, CaseIterable, Identifiable {
            case urgency, updated, newest, oldest, largest
            var id: String { rawValue }
            var label: String {
                switch self {
                case .urgency: return "Most urgent"
                case .updated: return "Recently updated"
                case .newest: return "Newest"
                case .oldest: return "Oldest"
                case .largest: return "Largest diff"
                }
            }
        }
        @AppStorage("github.queue.sortOrder") private var sortRaw = SortOrder.urgency.rawValue
        private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .urgency }

        private func isWatched(_ row: ViewerPr) -> Bool {
            guard let cwd = model.folder(forRepo: row.repo) else { return false }
            return model.trackedPr(cwd: cwd, number: row.pr.number) != nil
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                filters
                Divider().padding(.vertical, 2)
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(groups.enumerated()), id: \.element.repo) { index, group in
                                    let folded = collapsed.contains(group.repo)
                                    if index > 0 {
                                        Divider().padding(.top, 6)
                                    }
                                    RepoHeader(repo: group.repo, rows: group.rows,
                                               collapsed: folded,
                                               current: group.repo == currentRepo,
                                               toggle: { toggle(group.repo) },
                                               dismiss: { showing = false })
                                        .id(group.repo)
                                    if !folded {
                                        ForEach(group.rows) { row in
                                            QueueRow(row: row, reason: reason(row),
                                                     dismiss: { showing = false }) { open(row) }
                                        }
                                    }
                                }
                            }
                        }
                        .task(id: currentRepo) { reveal(currentRepo, proxy) }
                    }
                    // Tall enough for ~6 rows, then it scrolls: a popover that grows
                    // with a 40-PR queue runs off the screen.
                    .frame(maxHeight: listMaxHeight ?? .infinity)
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
                TrackedPrsButton(dismiss: { showing = false })
                Button { model.refreshViewerPrs(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Refresh your queue now")
                .clickCursor()
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
        }

        /// Slice and watch filter as two dropdowns on one line, instead of two chip rows.
        private var filters: some View {
            let inSlice = viewerPrRows(queue, slice: slice)
            let watchedCount = inSlice.filter(isWatched).count
            return HStack(spacing: 6) {
                Menu {
                    ForEach(ViewerPrSlice.allCases) { s in
                        Button { slice = s } label: {
                            menuItem(label(s), count: viewerPrCount(queue, slice: s), selected: slice == s)
                        }
                        .help(help(s))
                    }
                } label: {
                    filterLabel(label(slice), count: viewerPrCount(queue, slice: slice),
                                countColor: slice == .needsYou ? .orange : .secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(help(slice))
                .clickCursor()

                Menu {
                    ForEach(WatchFilter.allCases) { w in
                        Button { watchRaw = w.rawValue } label: {
                            menuItem(watchLabel(w),
                                     count: watchCount(w, total: inSlice.count, watched: watchedCount),
                                     selected: watch == w)
                        }
                    }
                } label: {
                    filterLabel(watchLabel(watch),
                                count: watchCount(watch, total: inSlice.count, watched: watchedCount),
                                countColor: .secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(watch == .any ? "Tracked and untracked PRs"
                      : watch == .watched ? "Only PRs a tracking agent is watching"
                      : "Only PRs nobody is watching yet")
                .clickCursor()
                Spacer(minLength: 0)

                Menu {
                    ForEach(SortOrder.allCases) { o in
                        Button { sortRaw = o.rawValue } label: {
                            menuItem(o.label, count: 0, selected: sort == o)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 9))
                        Text(sort.label).font(.system(size: 11, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sort order, applied inside each repo; repos follow their first PR")
                .clickCursor()
            }
            .padding(.horizontal, 10).padding(.bottom, 2)
        }

        private func filterLabel(_ text: String, count: Int, countColor: Color) -> some View {
            HStack(spacing: 4) {
                Text(text).font(.system(size: 11, weight: .medium))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(countColor)
                }
            }
        }

        private func menuItem(_ text: String, count: Int, selected: Bool) -> some View {
            let title = count > 0 ? "\(text)  \(count)" : text
            return selected ? AnyView(Label(title, systemImage: "checkmark")) : AnyView(Text(title))
        }

        private func watchLabel(_ w: WatchFilter) -> String {
            switch w {
            case .any: return "Any"
            case .watched: return "Watched"
            case .unwatched: return "Unwatched"
            }
        }

        private func watchCount(_ w: WatchFilter, total: Int, watched: Int) -> Int {
            switch w {
            case .any: return 0
            case .watched: return watched
            case .unwatched: return total - watched
            }
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
        private var rows: [ViewerPr] {
            let all = sorted(viewerPrRows(queue, slice: slice))
            switch watch {
            case .any: return all
            case .watched: return all.filter(isWatched)
            case .unwatched: return all.filter { !isWatched($0) }
            }
        }

        /// `viewerPrRows` already yields urgency order; the rest re-sort stably from
        /// the queue's own order, which is GitHub's `sort:updated`.
        private func sorted(_ rows: [ViewerPr]) -> [ViewerPr] {
            if sort == .urgency { return rows }
            let fetchOrder = Dictionary(queue.rows.enumerated().map { ($1.id, $0) },
                                        uniquingKeysWith: { a, _ in a })
            // GitHub's ISO-8601 UTC stamps order correctly as plain strings.
            let created = { (r: ViewerPr) in r.pr.createdAt ?? "" }
            let size = { (r: ViewerPr) in (r.pr.additions ?? 0) + (r.pr.deletions ?? 0) }
            let before: (ViewerPr, ViewerPr) -> Bool? = switch sort {
            case .urgency, .updated: { _, _ in nil }
            case .newest: { a, b in created(a) == created(b) ? nil : created(a) > created(b) }
            case .oldest: { a, b in created(a) == created(b) ? nil : created(a) < created(b) }
            case .largest: { a, b in size(a) == size(b) ? nil : size(a) > size(b) }
            }
            return rows.sorted { a, b in
                before(a, b) ?? ((fetchOrder[a.id] ?? .max) < (fetchOrder[b.id] ?? .max))
            }
        }

        /// The rows by repo, each repo placed where its most urgent PR would sit, so
        /// grouping never buries the one that's on fire under a quieter repo. Inside a
        /// repo the tracked PRs lead, each half keeping its urgency order.
        private var groups: [(repo: String, rows: [ViewerPr])] {
            var order: [String] = []
            var byRepo: [String: [ViewerPr]] = [:]
            for row in rows {
                if byRepo[row.repo] == nil { order.append(row.repo) }
                byRepo[row.repo, default: []].append(row)
            }
            return order.map { repo in
                let all = byRepo[repo] ?? []
                guard sort == .urgency, let cwd = model.folder(forRepo: repo) else { return (repo, all) }
                let isTracked = { (r: ViewerPr) in model.trackedPr(cwd: cwd, number: r.pr.number) != nil }
                return (repo, all.filter(isTracked) + all.filter { !isTracked($0) })
            }
        }

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
            if watch != .any, !viewerPrRows(queue, slice: slice).isEmpty {
                return watch == .watched ? "Nothing here is being watched." : "Everything here is already watched."
            }
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

    /// One PR in the queue, under its repo's header: number, tracked eye, checks,
    /// open threads and age on one line, the title (full text on hover) under it.
    private struct QueueRow: View {
        @Environment(AppModel.self) private var model
        let row: ViewerPr
        let reason: PrAttentionReason?
        /// Close the popover: jumping to a tracking agent takes you somewhere else,
        /// so leaving the queue floating over it would be in the way. Track and
        /// Agent spawn in the background and leave it open.
        let dismiss: () -> Void
        let onOpen: () -> Void
        /// Whether the pointer is over the row — the two actions ride on it.
        @State private var hovering = false
        @State private var confirmingClose = false

        private var pr: PullRequest { row.pr }
        /// Both actions need a working tree — the watching agent and the fresh
        /// session each stand in one. A review you owe on a repo you never cloned
        /// has neither, so the row keeps just its open action.
        private var cwd: String? { model.folder(forRepo: row.repo) }
        private var tracked: TrackedPr? {
            cwd.flatMap { model.trackedPr(cwd: $0, number: pr.number) }
        }

        var body: some View {
            Button(action: onOpen) { rowContent }
                .buttonStyle(.plain)
                .clickCursor()
                .help(helpText)
                // Floated, not inline: inline buttons take their width from the title,
                // so every title re-truncates the instant the pointer enters the row
                // (the lesson `RowHoverActions` is built around).
                .overlay(alignment: .trailing) { actions }
                .onHover { hovering = $0 }
                .contextMenu { menu }
                .closePrConfirmation($confirmingClose, pr: pr, cwd: cwd, model: model)
        }

        /// Facts on the first line, title on the second. The attention reason is
        /// not drawn — the orange comment count and red checks already say it — but
        /// stays in the hover text.
        private var rowContent: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(pr.checks.color).frame(width: 7, height: 7)
                    // Verbatim: an interpolated Int is localized, so #35875 read "#35,875".
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let t = tracked {
                        Button {
                            dismiss()
                            model.openTrackingSession(t)
                        } label: {
                            TrackBadge(state: t.state, compact: true)
                                .opacity(model.isTrackPending(t) ? 0.45 : 1)
                        }
                        .buttonStyle(.borderless)
                        .clickCursor()
                        .disabled(model.isTrackPending(t))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: pr.checks.icon).font(.system(size: 9))
                        Text(pr.checksText).font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(pr.checks.color)
                    if pr.unresolvedComments > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.fill").font(.system(size: 8))
                            Text(verbatim: "\(pr.unresolvedComments)").font(.system(size: 10))
                        }
                        .foregroundStyle(.orange)
                    }
                    if pr.draft {
                        Text("draft")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 4)
                    if let age = prAgeLabel(pr.createdAt) {
                        Text(age).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 10)
                Text(pr.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 13).padding(.trailing, 10)
            }
            .padding(.leading, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Track, Agent and GitHub, on hover. Track hands the PR to an agent that keeps
        /// watching it, Agent opens one session on it right now; both need a checkout,
        /// so a repo juancode has never opened gets only the GitHub button. That one is
        /// always there because a click on a mapped row opens the GitHub view instead.
        @ViewBuilder private var actions: some View {
            if hovering {
                HStack(spacing: 1) {
                    if let cwd { checkoutActions(cwd) }
                    iconButton("arrow.up.right.square", help: "Open on GitHub") {
                        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(pill)
                .padding(.trailing, 6)
            }
        }

        @ViewBuilder private func checkoutActions(_ cwd: String) -> some View {
            if let t = tracked {
                iconButton("eye.slash", help: "Stop tracking this PR") {
                    model.untrackPr(t.id)
                }
                .disabled(!model.supports(.trackedPrs))
            } else {
                iconButton("eye", help: model.unavailable(.trackedPrs)
                    ?? "Track: an agent watches this PR, fixes the obvious and escalates the rest") {
                    model.trackPr(pr, cwd: cwd)
                }
                .disabled(!model.supports(.trackedPrs))
            }
            iconButton("terminal",
                       help: "Agent: a fresh session on this PR, seeded with its details") {
                model.workOnPr(pr, cwd: cwd)
            }
        }

        /// The same frosted pill the sidebar's hover actions wear (`RowHoverActions`),
        /// so a floating control reads the same wherever it appears.
        private var pill: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            return shape
                .fill(.ultraThickMaterial)
                .overlay(shape.fill(Color.appHairline(0.10)))
                .overlay(shape.strokeBorder(Color.appHairline(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
        }

        private func iconButton(_ symbol: String, help: String,
                                action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(help)
            .clickCursor()
        }

        /// The same actions without the hover, for a pointer that never rests: the
        /// menu is also the only place Untrack lives.
        @ViewBuilder private var menu: some View {
            Button("Open on GitHub") {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
            if let cwd {
                Divider()
                if let t = tracked {
                    Button("Untrack") { model.untrackPr(t.id) }
                        .disabled(!model.supports(.trackedPrs))
                } else {
                    Button("Track") { model.trackPr(pr, cwd: cwd) }
                        .disabled(!model.supports(.trackedPrs))
                }
                Button("Work on PR") { model.workOnPr(pr, cwd: cwd) }
            }
            ClosePrMenuItem(confirming: $confirmingClose)
        }

        private var helpText: String {
            let where_ = model.folder(forRepo: row.repo) == nil
                ? "opens on github.com — no local checkout"
                : "opens in the GitHub view"
            let why = reason.map { "\n\($0.label)" } ?? ""
            return "\(pr.title)\(why)\n\(row.repo) #\(pr.number) · \(where_)"
        }
    }

    /// Beside refresh: how many PRs have a watching agent, and the list of them
    /// behind a click — a row jumps to its agent's session, the eye stops the watch.
    private struct TrackedPrsButton: View {
        @Environment(AppModel.self) private var model
        let dismiss: () -> Void
        @State private var showing = false

        var body: some View {
            let list = model.trackedList
            Button { showing = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: "eye").font(.system(size: 10))
                    if !list.isEmpty {
                        Text(verbatim: "\(list.count)").font(.system(size: 10).monospacedDigit())
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(list.isEmpty ? "No PRs tracked" : "\(list.count) tracked PR\(list.count == 1 ? "" : "s")")
            .clickCursor()
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                content(list).frame(width: 300)
            }
        }

        @ViewBuilder private func content(_ list: [TrackedPr]) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tracked PRs").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                if list.isEmpty {
                    Text("Nothing tracked. Hover a PR and hit the eye, or use Track all.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { t in row(t) }
                        }
                    }
                    .frame(maxHeight: 360)
                    .padding(.bottom, 4)
                }
            }
        }

        private func row(_ t: TrackedPr) -> some View {
            HStack(spacing: 6) {
                Button {
                    showing = false
                    dismiss()
                    model.openTrackingSession(t)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: "#\(t.number)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            TrackBadge(state: t.state)
                            Text(t.repoNwo ?? (t.cwd as NSString).lastPathComponent)
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Text(t.title).font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isTrackPending(t) ? "\(t.title)\nStarting its agent…"
                      : "\(t.title)\nOpen the session tracking it")
                .clickCursor()
                .disabled(model.isTrackPending(t))
                Button { model.untrackPr(t.id) } label: {
                    Image(systemName: "eye.slash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(!model.supports(.trackedPrs))
                .help("Stop tracking (the agent session stays)")
                .clickCursor()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    /// A repo's section: its name, and Track all for the PRs in it nobody is
    /// watching yet. Each track spawns its own agent session, so it asks first.
    private struct RepoHeader: View {
        @Environment(AppModel.self) private var model
        let repo: String
        let rows: [ViewerPr]
        let collapsed: Bool
        /// The selected session works in this repo.
        var current = false
        let toggle: () -> Void
        let dismiss: () -> Void
        @State private var confirming = false

        private var cwd: String? { model.folder(forRepo: repo) }
        private var untracked: [PullRequest] {
            guard let cwd else { return [] }
            return rows.map(\.pr).filter { model.trackedPr(cwd: cwd, number: $0.number) == nil }
        }

        var body: some View {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(repo).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(current ? Color.accentColor : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "\(rows.count)")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                        if current {
                            Text("this session")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show \(repo)'s PRs" : "Minimise \(repo)")
                .clickCursor()
                trackAll
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(current ? Color.accentColor.opacity(0.10) : Color.appHairline(0.06))
            .overlay(alignment: .leading) {
                if current { Rectangle().fill(Color.accentColor).frame(width: 2) }
            }
            .padding(.bottom, 2)
        }

        @ViewBuilder private var trackAll: some View {
            let pending = untracked
            if cwd == nil {
                Image(systemName: "icloud").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("No local checkout of \(repo), so its PRs can't be tracked")
            } else if !pending.isEmpty {
                Button { confirming = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eye").font(.system(size: 9))
                        Text("Track all").font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!model.supports(.trackedPrs))
                .help(model.unavailable(.trackedPrs)
                    ?? "Track the \(pending.count) untracked PR\(pending.count == 1 ? "" : "s") here: one watching agent each")
                .clickCursor()
                .confirmationDialog(
                    "Track \(pending.count) PR\(pending.count == 1 ? "" : "s") in \(repo)?",
                    isPresented: $confirming
                ) {
                    Button("Track \(pending.count)") {
                        guard let cwd else { return }
                        dismiss()
                        model.trackPrs(pending, cwd: cwd)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Each one starts its own agent session on its own worktree.")
                }
            }
        }
    }
}
