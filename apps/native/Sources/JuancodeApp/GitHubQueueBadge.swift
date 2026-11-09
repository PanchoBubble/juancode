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
// offers tracking and agent actions. Selecting a row opens its detail — diff,
// threads, checks and per-comment send-to-agent.
//
// Attention first: until you pick a chip the queue opens on Needs you, the badge's
// loud number is what wants you and the rest of the plate is the quiet one beside it,
// and each row that wants you says why. What wants you is the core's reason plus any
// tracking agent stopped on your decision (`GitHubQueueAttention.swift`).

import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

struct GitHubQueueBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    /// The chip that was on last time. Persisted: which half of the queue you live
    /// in is a habit, not a per-launch decision. Nil until someone picks one, which
    /// opens the attention view; an explicit pick (All included) is kept.
    @AppStorage(ViewerPrSlice.storageKey) private var filterRaw: String?

    private var filter: ViewerPrSlice { ViewerPrSlice(storedRaw: filterRaw) }

    private var queue: ViewerPrResult { model.viewerPrs }

    /// Neither number follows the chip, or the toolbar would lie whenever the chip
    /// wasn't "All": the loud one is what wants you, the quiet one the whole plate.
    private var tally: ViewerPrTally { model.viewerPrQueueTally }

    var body: some View {
        Button {
            showing = true
            // Floored to one search a minute inside `refreshViewerPrs`, so opening
            // the popover repeatedly costs nothing.
            model.refreshViewerPrs()
        } label: {
            let tally = tally
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                if tally.actionable > 0 {
                    Text(verbatim: "\(tally.actionable)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    if tally.quiet > 0 {
                        Text(verbatim: "/\(tally.total)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if tally.total > 0 {
                    Text(verbatim: "\(tally.total)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badgeLabel)
        }
        .foregroundStyle(tally.actionable > 0 ? Color.orange : Color.primary)
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
        let tally = tally
        var parts: [String] = []
        if tally.actionable > 0 {
            parts.append("\(tally.actionable) need\(tally.actionable == 1 ? "s" : "") you")
        }
        parts += ["\(tally.mine) yours", "\(tally.reviewing) to review"]
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
        /// Unfold and scroll to the selected session's repo when the selection changes.
        /// The popover opens on demand, so it does; the rail's queue is global and keeps
        /// its folds and scroll position across session switches.
        var revealsSelectedRepo = true
        @State private var agentPromptRow: ViewerPr?

        private var queue: ViewerPrResult { model.viewerPrs }
        /// Rows whose tracking agent is waiting on you — part of what Needs you means.
        private var decisions: Set<String> { model.viewerPrDecisionIDs }

        /// Minimised repos, newline-joined. Persisted: a repo you fold away is one
        /// you don't want to see next launch either.
        @AppStorage("github.queue.collapsedRepos") private var collapsedRaw = ""
        private var collapsed: Set<String> {
            Set(collapsedRaw.split(separator: "\n").map(String.init))
        }
        private func toggle(_ repo: String) {
            var set = collapsed
            if set.contains(repo) { set.remove(repo) } else { set.insert(repo) }
            // Animated so the rows fade in/out and the headers below slide, instead of snapping.
            withAnimation(.easeOut(duration: 0.18)) {
                collapsedRaw = set.sorted().joined(separator: "\n")
            }
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
                                    RepoHeader(repo: group.repo, rows: group.rows,
                                               collapsed: folded,
                                               current: group.repo == currentRepo,
                                               toggle: { toggle(group.repo) },
                                               dismiss: { showing = false })
                                        .id(group.repo)
                                        .panelRowFocus(.prs, id: group.repo)
                                    if !folded {
                                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                                            QueueRow(row: row, reason: reason(row), rowActions: rowActions(row),
                                                     dismiss: { showing = false }) { open(row) }
                                                .id(row.id)
                                                .panelRowFocus(.prs, id: row.id)
                                                .overlay(alignment: .top) {
                                                    if i > 0 {
                                                        Rectangle().fill(Color.appDivider).frame(height: 1)
                                                            .padding(.horizontal, 10)
                                                    }
                                                }
                                                .transition(.opacity)
                                        }
                                    }
                                }
                            }
                        }
                        .panelNavigationRows(navigationRows)
                        .panelNavigationScroll(.prs, proxy: proxy)
                        .task(id: revealsSelectedRepo ? currentRepo : nil) {
                            if revealsSelectedRepo { reveal(currentRepo, proxy) }
                        }
                    }
                    // Tall enough for ~6 rows, then it scrolls: a popover that grows
                    // with a 40-PR queue runs off the screen.
                    .frame(maxHeight: listMaxHeight ?? .infinity)
                }
            }
            .padding(.bottom, 6)
            .sheet(item: $agentPromptRow) { row in
                if let cwd = model.folder(forRepo: row.repo) {
                    PrAgentPromptSheet(pr: row.pr, cwd: cwd)
                }
            }
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
                ReviewPrButton()
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
            let decisions = decisions
            let inSlice = viewerPrRows(queue, slice: slice, decisions: decisions)
            let watchedCount = inSlice.filter(isWatched).count
            return HStack(spacing: 6) {
                Menu {
                    ForEach(ViewerPrSlice.allCases) { s in
                        Button { slice = s } label: {
                            menuItem(label(s), count: viewerPrCount(queue, slice: s, decisions: decisions),
                                     selected: slice == s)
                        }
                        .help(help(s))
                    }
                } label: {
                    filterLabel(label(slice), count: inSlice.count,
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

        /// The queue under the active chip, most urgent first (see `viewerPrRows`).
        private var rows: [ViewerPr] {
            let all = sorted(viewerPrRows(queue, slice: slice, decisions: decisions))
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
        /// repo tracked PRs lead in urgency mode, then stacks stay together in
        /// dependency order regardless of the selected sort.
        private var groups: [(repo: String, rows: [ViewerPr])] {
            var order: [String] = []
            var byRepo: [String: [ViewerPr]] = [:]
            for row in rows {
                if byRepo[row.repo] == nil { order.append(row.repo) }
                byRepo[row.repo, default: []].append(row)
            }
            return order.map { repo in
                let all = byRepo[repo] ?? []
                let cwd = model.folder(forRepo: repo)
                let prioritized: [ViewerPr]
                if sort == .urgency, let cwd {
                    let isTracked = { (r: ViewerPr) in model.trackedPr(cwd: cwd, number: r.pr.number) != nil }
                    prioritized = all.filter(isTracked) + all.filter { !isTracked($0) }
                } else {
                    prioritized = all
                }
                let byURL = Dictionary(prioritized.map { ($0.pr.url, $0) },
                                       uniquingKeysWith: { first, _ in first })
                let context = (cwd.flatMap { model.prs($0)?.prs } ?? []) + queue.rows.map(\.pr)
                let ordered = groupPrStacks(prioritized.map(\.pr), in: context)
                    .compactMap { byURL[$0.url] }
                return (repo, ordered)
            }
        }

        // Publish the full visible order outside the lazy stack, so keyboard browsing
        // can reach rows that have not been mounted yet. Folded repos remain reachable.
        private var navigationRows: [PanelNavigationRow] {
            let groups = groups
            let initialID = groups.first { !collapsed.contains($0.repo) }?.rows.first?.id
            return groups.flatMap { group in
                let header = PanelNavigationRow(id: group.repo, open: { toggle(group.repo) })
                guard !collapsed.contains(group.repo) else { return [header] }
                return [header] + group.rows.map { row in
                    PanelNavigationRow(id: row.id,
                                       actions: rowActions(row).filter(\.enabled).map(\.navigationAction),
                                       isInitial: row.id == initialID, open: { open(row) })
                }
            }
        }

        // Mouse and keyboard share the order, availability and exact action closure.
        private func rowActions(_ row: ViewerPr) -> [QueueAction] {
            let pr = row.pr
            var actions: [QueueAction] = []
            if let cwd = model.folder(forRepo: row.repo) {
                let tracked = model.trackedPr(cwd: cwd, number: pr.number)
                actions.append(QueueAction(
                    id: "tracking", symbol: tracked == nil ? "eye" : "eye.slash",
                    label: tracked == nil ? "Track PR" : "Stop tracking PR",
                    help: model.unavailable(.trackedPrs)
                        ?? (tracked == nil ? "Track: an agent watches this PR, fixes the obvious and escalates the rest"
                            : "Stop tracking this PR"),
                    enabled: model.supports(.trackedPrs)
                ) {
                    if let tracked { model.untrackPr(tracked.id) }
                    else { model.trackPr(pr, cwd: cwd) }
                })
                actions.append(QueueAction(id: "agent", symbol: "terminal", label: "Agent",
                    help: "Agent: send the PR link and your prompt to a fresh agent session") {
                    agentPromptRow = row
                })
                actions.append(QueueAction(id: "review", symbol: "text.bubble", label: "Review diff",
                    help: "Review: the PR's diff against its base in the full-width review — comment on lines, send them to its agent") {
                    showing = false
                    model.openPrDiffReview(pr, cwd: cwd)
                })
            }
            actions.append(QueueAction(id: "github", symbol: "arrow.up.right.square",
                                       label: "Open on GitHub", help: "Open on GitHub") {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            })
            return actions
        }

        /// Why the row wants you, in the words the row shows; nil when it asks nothing.
        private func reason(_ row: ViewerPr) -> String? { row.queueAttentionLabel(decisions: decisions) }

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
            case .needsYou: return "Red CI, changes requested, open threads, reviews you owe, agents waiting on you"
            }
        }

        private var emptyText: String {
            guard queue.available else { return queue.error ?? "Loading your queue…" }
            if watch != .any, !viewerPrRows(queue, slice: slice, decisions: decisions).isEmpty {
                return watch == .watched ? "Nothing here is being watched." : "Everything here is already watched."
            }
            switch slice {
            case .all: return "Nothing on your plate — no open PRs of yours, no reviews waiting."
            case .mine: return "No open PRs of yours."
            case .review: return "No reviews waiting on you."
            case .needsYou:
                let quiet = queue.rows.count
                return "Nothing needs you — no red CI, no changes requested, no open threads."
                    + (quiet > 0 ? " \(quiet) quiet PR\(quiet == 1 ? "" : "s") under All." : "")
            }
        }

        /// A row opens where the PR actually lives: in the GitHub view when juancode
        /// has that repo open (diff, threads, agent all reachable from there), on
        /// github.com when it doesn't — a review you owe on a repo you never cloned
        /// is still worth one click.
        private func open(_ row: ViewerPr) {
            showing = false
            if let cwd = model.folder(forRepo: row.repo) {
                model.github.navOrder = rows.compactMap { item in
                    model.folder(forRepo: item.repo).map { GitHubModel.PrNavRow(cwd: $0, pr: item.pr) }
                }
                model.github.select(cwd: cwd, pr: row.pr)
                model.openGitHub(scope: cwd)
            } else if let url = URL(string: row.pr.url) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private struct QueueAction: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let help: String
        var enabled = true
        let perform: () -> Void

        var navigationAction: PanelRowAction {
            PanelRowAction(id: id, label: label, perform: perform)
        }
    }

    /// One PR in the queue, under its repo's header: number, stack link, open
    /// threads and age (or, on hover, the actions) on one line, the title (full
    /// text on hover) under it, and the checks dot and tracked eye in a lead column.
    private struct QueueRow: View {
        @Environment(AppModel.self) private var model
        let row: ViewerPr
        /// Why this row wants you ("CI failing", "decision needed"…), or nil.
        let reason: String?
        let rowActions: [QueueAction]
        /// Close the popover: jumping to a tracking agent takes you somewhere else,
        /// so leaving the queue floating over it would be in the way. Track and
        /// Agent spawn in the background and leave it open.
        let dismiss: () -> Void
        let onOpen: () -> Void
        /// Whether the pointer is over the row — the actions take the age's place.
        @State private var hovering = false
        @State private var showingStack = false
        @State private var eyeHovering = false
        @State private var confirmingClose = false
        @State private var availableWidth: CGFloat = 0

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
                .focusEffectDisabled()
                .modifier(SelectableRowBackground(selected: false))
                .pointerCursor()
                .onHover { hovering = $0 }
                .contextMenu { menu }
                .closePrConfirmation($confirmingClose, pr: pr, cwd: cwd, model: model)
        }

        /// PR identity, stack position and tracking share the facts line. The
        /// status stripe leaves the title aligned with the row's leading edge.
        private var rowContent: some View {
            rowLayout(countsOnTop: availableWidth >= 440)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .overlay(alignment: .leading) {
                Rectangle().fill(pr.checks.color).frame(width: 2)
            }
        }

        private func rowLayout(countsOnTop: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Verbatim: an interpolated Int is localized, so #35875 read "#35,875".
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(helpText)
                    if let base = pr.baseBranch, !base.isEmpty {
                        Image(systemName: base == "main" || base == "master"
                              ? "arrow.triangle.merge" : "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Targets \(base)")
                            .accessibilityLabel("Targets branch \(base)")
                    }
                    // Always shown, not a hover action: being one of a stack is a
                    // fact about the PR, like its number.
                    if let stack {
                        PrStackBadge(stack: stack, number: pr.number, showing: $showingStack)
                    }
                    if let t = tracked { trackEye(t) }
                    if let t = tracked, let chain = model.chain(of: .trackedPr, ref: t.id) {
                        ChainBadge(chain: chain, member: ChainMemberRef(kind: .trackedPr, ref: t.id),
                                   compact: true, willOpen: dismiss)
                    }
                    if pr.unresolvedComments > 0 {
                        Image(systemName: "bubble.left.fill").font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .cornerCount(pr.unresolvedComments, color: .orange)
                            .padding(.trailing, 4)
                            .help("\(pr.unresolvedComments) unresolved review threads")
                    }
                    reviewIcon
                    reviewAssignmentIcons
                    if let reason {
                        // The reason is the status: what this row is in Needs you for.
                        Text(reason)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    if pr.draft {
                        Text("draft")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 4)
                    if countsOnTop, let counts = pr.diffCounts {
                        DiffStatLabel(counts: counts).fixedSize()
                    }
                    if hovering || model.panelNavigation.isFocused(.prs, row: row.id) {
                        actions
                    } else if let age = prAgeLabel(pr.createdAt) {
                        Text(age).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: Self.factsHeight)
                HStack(spacing: 6) {
                    Text(pr.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .help(helpText)
                    Spacer(minLength: 0)
                    if !countsOnTop, let counts = pr.diffCounts {
                        DiffStatLabel(counts: counts)
                            .fixedSize()
                    }
                }
            }
        }

        private var reviewAssignedToMe: Bool {
            let viewer = model.viewerPrs.viewer
            return row.reason == .reviewRequested || (!viewer.isEmpty && pr.reviewRequests.contains {
                $0.caseInsensitiveCompare(viewer) == .orderedSame
            })
        }

        private var reviewAssignmentIcons: some View {
            HStack(spacing: 4) {
                let reviewers = pr.assignedReviewers
                let assigned = !reviewers.isEmpty || reviewAssignedToMe
                HStack(spacing: 2) {
                    Image(systemName: assigned ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    if reviewers.count > 1 {
                        Text(verbatim: "\(reviewers.count)")
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(assigned ? Color.secondary : Color.orange)
                .contentShape(Rectangle())
                .help(reviewHelpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reviewHelpText)
                if reviewAssignedToMe {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("Your review is requested")
                        .accessibilityLabel("Your review is requested")
                }
            }
            .font(.system(size: 10))
            .fixedSize()
        }

        private var reviewHelpText: String {
            var lines: [String] = []
            switch pr.reviewDecisionKind {
            case .approved: lines.append("Approved")
            case .changesRequested: lines.append("Changes requested")
            case .reviewRequired: lines.append("Review required")
            case .none: break
            }
            if !pr.reviewRequests.isEmpty {
                lines.append("Review requested: " + pr.reviewRequests.joined(separator: ", "))
            }
            if let reviewers = pr.reviewers, !reviewers.isEmpty {
                lines.append("Submitted a review: " + reviewers.joined(separator: ", "))
            }
            if reviewAssignedToMe { lines.append("Your review is requested") }
            if pr.assignedReviewers.isEmpty && !reviewAssignedToMe {
                lines.append("No reviewer assigned")
            }
            return lines.joined(separator: "\n")
        }

        /// The review verdict as a bare glyph — the GitHub view's chip without its
        /// word, same symbols and colours. "Review required" draws nothing: it's every
        /// open PR's default on a repo that requires review, so it would say nothing.
        @ViewBuilder private var reviewIcon: some View {
            switch pr.reviewDecisionKind {
            case .approved:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                    .foregroundStyle(.green)
                    .help(reviewHelpText)
            case .changesRequested:
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help(reviewHelpText)
            case .reviewRequired, .none:
                EmptyView()
            }
        }

        /// The stack this PR sits in, looked up among its checkout's PRs and the
        /// queue's own rows.
        private var stack: PrStack? {
            PrStack.containing(
                pr, in: (cwd.flatMap { model.prs($0)?.prs } ?? []) + model.viewerPrs.rows.map(\.pr)
            )
        }

        /// The facts line's height: tall enough for the 22pt action cells, so the
        /// row doesn't grow when the pointer enters it.
        private static let factsHeight: CGFloat = 22

        /// A separate eye button on the facts line opens the tracking session.
        private func trackEye(_ t: TrackedPr) -> some View {
            let badge = TrackBadge(state: t.state,
                                   waiting: model.activity(t.sessionId) == .waitingInput,
                                   compact: true, compactSize: 11)
            return Button {
                dismiss()
                model.openTrackingSession(t)
            } label: {
                badge
                    .frame(width: 22, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(badge.compactColor.opacity(eyeHovering ? 0.28 : 0.14)))
                    .contentShape(Rectangle())
                    .opacity(model.isTrackPending(t) ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .onHover { eyeHovering = $0 }
            .disabled(model.isTrackPending(t))
        }

        /// Track, Agent, Review and GitHub, at the end of the facts line on hover.
        /// Track hands the PR to an agent that keeps watching it, Agent asks for a
        /// prompt and agent before opening a session, Review opens the full-width
        /// diff; all three need a checkout, so a repo juancode has never opened gets
        /// only the GitHub button. That one is always there because a click on a
        /// mapped row opens the GitHub view instead.
        private var actions: some View {
            HStack(spacing: 1) {
                ForEach(rowActions) { action in
                    HoverCellButton(symbol: action.symbol, help: action.help,
                                    focused: model.panelNavigation.isFocused(.prs, row: row.id)
                                        && model.panelNavigation.cursor.actionID == action.id,
                                    action: action.perform)
                        .disabled(!action.enabled)
                }
            }
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
                Button("Review Diff") {
                    dismiss()
                    model.openPrDiffReview(pr, cwd: cwd)
                }
            }
            ClosePrMenuItem(confirming: $confirmingClose)
        }

        private var helpText: String {
            let where_ = model.folder(forRepo: row.repo) == nil
                ? "opens on github.com — no local checkout"
                : "opens in the GitHub view"
            let why = reason.map { "\n\($0)" } ?? ""
            var lines = ["\(pr.title)\(why)", "\(row.repo) #\(pr.number) · \(where_)"]
            if !pr.author.isEmpty { lines.append("Author: \(pr.author)") }
            if !pr.assignees.isEmpty {
                lines.append("Assigned to: " + pr.assignees.joined(separator: ", "))
            }
            lines.append(reviewHelpText)
            return lines.joined(separator: "\n")
        }
    }

    /// Beside refresh: how many PRs have a watching agent, and the list of them
    /// behind a click — a row jumps to its agent's session, the eye stops the watch.
    /// "Review PR": opens the URL sheet.
    private struct ReviewPrButton: View {
        @State private var showing = false

        var body: some View {
            Button { showing = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "link.badge.plus").font(.system(size: 10))
                    Text("Review PR").font(.system(size: 10))
                }
            }
            .buttonStyle(.borderless)
            .help("Review PR… — open any GitHub pull request from its URL")
            .clickCursor()
            .sheet(isPresented: $showing) { ReviewPrSheet() }
        }
    }

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
                            TrackBadge(state: t.state,
                                       waiting: model.activity(t.sessionId) == .waitingInput)
                            if let chain = model.chain(of: .trackedPr, ref: t.id) {
                                ChainBadge(chain: chain, member: ChainMemberRef(kind: .trackedPr, ref: t.id),
                                           willOpen: { showing = false; dismiss() })
                            }
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
        @State private var hovering = false

        private var cwd: String? { model.folder(forRepo: repo) }
        private var untracked: [PullRequest] {
            guard let cwd else { return [] }
            return rows.map(\.pr).filter { model.trackedPr(cwd: cwd, number: $0.number) == nil }
        }

        var body: some View {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 10)
                        Text(repo).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(current ? Color.accentColor : .primary)
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        Text(verbatim: "\(rows.count)")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                            .fixedSize()
                        // Fixed size: squeezed, the badge wrapped letter by letter
                        // into a tall bubble instead of letting the name truncate.
                        if current {
                            Text("this session")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(collapsed ? "Show \(repo)'s PRs" : "Minimise \(repo)")
                // Hover lights the whole bar (below), not a rounded chip on the name.
                .pointerCursor()
                trackAll
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(current ? Color.appSelection
                        : hovering ? Color.appHairline(0.08) : Color.appBand)
            .overlay(alignment: .leading) {
                if current { Rectangle().fill(Color.accentColor).frame(width: 2) }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.10), value: hovering)
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
                    .fixedSize()
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

/// A queue row's inline hover action: a borderless 22pt square whose whole cell,
/// not just its glyph, takes the click, with a faint fill under the pointer.
private struct HoverCellButton: View {
    let symbol: String
    let help: String
    var focused = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(focused ? Color.accentColor.opacity(0.3)
                          : Color.appHairline(hovering && isEnabled ? 0.18 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .clickCursor()
        .onHover { hovering = $0 }
    }
}
