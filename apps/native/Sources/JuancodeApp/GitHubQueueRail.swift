// The right rail supports full-height tabs and an optional stack of independently
// visible, reorderable panels. Visited destinations stay mounted in either layout
// so filters, scroll positions and review drafts survive navigation.

import AppKit
import SwiftUI
import JuancodeCore
import JuancodeClient

enum RightRailPanel: String, CaseIterable, Identifiable {
    case worktree, oracle, prs, tickets, chains
    /// The retired Diff panel's name for Worktree.
    static var diff: RightRailPanel { .worktree }
    var id: String { rawValue }
    /// Overview's queues; Worktree is its own tab.
    var isQueue: Bool { self != .worktree }
    var focusTarget: PanelFocusTarget? {
        switch self {
        case .oracle: .oracles
        case .prs: .prs
        case .chains: .chains
        case .tickets: .linearTickets
        case .worktree: nil
        }
    }
    var title: String {
        switch self {
        case .worktree: "Worktree"
        case .oracle: "Oracles"
        case .prs: "PRs"
        case .chains: "Chains"
        case .tickets: "Tickets"
        }
    }
    var icon: String {
        switch self {
        case .worktree: "folder"
        case .oracle: "sparkles"
        case .prs: "arrow.triangle.pull"
        case .chains: "link"
        case .tickets: "checklist"
        }
    }
}

struct RightRailPanels: View {
    @Environment(AppModel.self) private var model
    /// Shared with the old popover's key, so the chip you lived on carries over; a
    /// fresh install (nothing stored) opens on what needs you.
    @AppStorage(ViewerPrSlice.storageKey) private var filterRaw: String?
    // Observed so a shortcut's write (`RightRailPrefs.setOpen`) re-renders the rail;
    // the state is read whole through `RightRailPrefs.state`.
    @AppStorage(RightRailPrefs.viewKey) private var viewRaw: String?
    @AppStorage(RightRailPrefs.queueKey) private var queueRaw: String?
    @AppStorage(RightRailPrefs.orderKey) private var orderRaw: String?
    @AppStorage(RightRailPrefs.stackedKey) private var stacked = false
    @AppStorage(RightRailPrefs.visibleKey) private var visibleRaw: String?
    @AppStorage(RightRailPrefs.stackOrderKey) private var stackOrderRaw: String?
    @AppStorage(RightRailPrefs.stackSizesKey) private var sizesRaw = "{}"
    /// Commit / Push / Create PR on the selected checkout. Here so a write's note
    /// outlives a tab switch.
    @State private var gitStore = WorktreeGitStore()
    /// Here so the hourly refresh and the project scope run whichever tab is up.
    @State private var ticketsStore = LinearTicketsStore()
    /// Destinations visited since the rail appeared. They stay mounted (hidden) so a
    /// switch back finds them as they were; unvisited ones cost nothing.
    @State private var mounted: Set<RightRailPanel> = []

    init() {
        // Older layouts (the stacked accordion, the Diff panel) are rewritten once,
        // before the first read, so the shortcuts and this view agree from then on.
        RightRailPrefs.migrate(.standard)
    }

    private var prefs: RightRailPrefs.State {
        _ = (viewRaw, queueRaw, orderRaw)
        return RightRailPrefs.state(RightRailPrefs.Stored(.standard))
    }

    private func show(_ panel: RightRailPanel) {
        RightRailPrefs.stored(prefs.showing(panel.rawValue)).write(to: .standard)
    }

    private var selectedMeta: SessionMeta? {
        guard let id = model.selection else { return nil }
        return model.sessions.first(where: { $0.id == id })
    }

    /// The selected session's project (its main checkout): what Tickets scope to.
    private var root: String? {
        selectedMeta.map { model.repoRoot(forSession: $0) }
    }

    private var gitRefreshKey: String {
        guard let ctx = model.worktreeContext else { return "" }
        return ctx.sessionId + "\u{0}" + ctx.checkout + "\u{0}"
            + (model.changeStatBySession[ctx.sessionId]?.signature ?? "")
    }

    private var stack: RightRailPrefs.Stack {
        _ = (visibleRaw, stackOrderRaw)
        return RightRailPrefs.stack()
    }

    private var visiblePanels: [RightRailPanel] {
        if stacked { return stack.shown.compactMap(RightRailPanel.init(rawValue:)) }
        return [RightRailPanel(rawValue: prefs.destination) ?? .worktree]
    }

    var body: some View {
        let p = prefs
        let visible = visiblePanels
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if stacked { Text("Panels").font(.system(size: 11, weight: .semibold)).padding(.leading, 10) }
                else { tabBar(p) }
                Spacer(minLength: 0)
                Button { stacked.toggle() } label: {
                    Image(systemName: stacked ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .foregroundStyle(stacked ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(stacked ? "Use tabs" : "Stack panels together")
                .accessibilityLabel(stacked ? "Use tabs" : "Stack panels together")
            }
            Divider()
            if stacked {
                stackSelector
                Divider()
            } else if p.view == .overview {
                queueSelector(p, active: visible[0])
                Divider()
            }
            GeometryReader { geometry in
                let frames = panelFrames(visible, height: geometry.size.height)
                ZStack(alignment: .topLeading) {
                    ForEach(RightRailPanel.allCases) { panel in
                        if visible.contains(panel) || mounted.contains(panel) {
                            VStack(spacing: 0) {
                                if stacked { stackHeader(panel) }
                                destination(panel)
                                    .modifier(RailPanelNavigation(panel: panel))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                            .frame(width: geometry.size.width,
                                   height: frames[panel]?.height ?? geometry.size.height,
                                   alignment: .top)
                            .clipped()
                            .offset(y: frames[panel]?.minY ?? 0)
                            .modifier(RailDestinationVisibility(active: visible.contains(panel)))
                        }
                    }
                    if stacked {
                        ForEach(Array(visible.dropLast())) { panel in
                            if let index = visible.firstIndex(of: panel),
                               let frame = frames[panel], let next = frames[visible[index + 1]] {
                                DragResizeHandle(axis: .horizontal,
                                    value: sizeBinding(panel, next: visible[index + 1],
                                                       firstHeight: frame.height, secondHeight: next.height),
                                    min: min(60, (frame.height + next.height) / 3),
                                    max: frame.height + next.height - min(60, (frame.height + next.height) / 3),
                                    invert: false)
                                    .offset(y: frame.maxY - 7)
                                    .zIndex(2)
                            }
                        }
                        if visible.isEmpty {
                            Text("Choose panels above to show them here.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appSurface)
        .onChange(of: visible, initial: true) { old, new in
            mounted.formUnion(new)
            for panel in old where !new.contains(panel) {
                releaseKeyboard(leaving: panel, for: new.first ?? .worktree)
            }
        }
        // Branch state for the git actions: re-read when the checkout or its change
        // signature moves. The Worktree viewer reads the change itself.
        .task(id: gitRefreshKey) { await gitStore.refresh(root: model.worktreeContext?.checkout, model: model) }
        .task { await ticketsStore.run() }
        // Tickets are project-scoped: the count follows the selected project even
        // while another destination is up.
        .onChange(of: root, initial: true) { ticketsStore.setRoot(root) }
    }

    // MARK: Stacked layout

    private var sizes: [String: Double] {
        guard let data = sizesRaw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return values.filter { $0.value.isFinite && $0.value > 0 }
    }

    private func panelFrames(_ panels: [RightRailPanel], height: CGFloat) -> [RightRailPanel: CGRect] {
        let weights = panels.map { sizes[$0.rawValue] ?? 1 }
        let total = weights.reduce(0, +)
        var y: CGFloat = 0
        var frames: [RightRailPanel: CGRect] = [:]
        for (index, panel) in panels.enumerated() {
            let h = height * weights[index] / max(total, .leastNonzeroMagnitude)
            frames[panel] = CGRect(x: 0, y: y, width: 0, height: h)
            y += h
        }
        return frames
    }

    private func sizeBinding(_ panel: RightRailPanel, next: RightRailPanel,
                             firstHeight: Double, secondHeight: Double) -> Binding<Double> {
        Binding(get: { firstHeight }, set: { height in
            var values = sizes
            let combined = (values[panel.rawValue] ?? 1) + (values[next.rawValue] ?? 1)
            let fraction = height / max(firstHeight + secondHeight, 1)
            values[panel.rawValue] = combined * fraction
            values[next.rawValue] = combined * (1 - fraction)
            if let data = try? JSONEncoder().encode(values), let raw = String(data: data, encoding: .utf8) {
                sizesRaw = raw
            }
        })
    }

    private func toggle(_ panel: RightRailPanel) {
        RightRailPrefs.storeStack(stack.setting(panel.rawValue, shown: !stack.visible.contains(panel.rawValue)))
    }

    private func move(_ panel: RightRailPanel, before target: RightRailPanel) {
        RightRailPrefs.storeStack(stack.moving(panel.rawValue, before: target.rawValue))
    }

    private var stackSelector: some View {
        HStack(spacing: 2) {
            ForEach(stack.order.compactMap(RightRailPanel.init(rawValue:))) { panel in
                let selected = stack.visible.contains(panel.rawValue)
                Button { toggle(panel) } label: {
                    ViewThatFits(in: .horizontal) {
                        selectorLabel(panel, selected: selected, titled: true)
                        selectorLabel(panel, selected: selected, titled: false)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.appSelection : Color.clear))
                }
                .buttonStyle(.plain)
                .help("\(selected ? "Hide" : "Show") \(panel.title). Drag to reorder; right-click for more.")
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .modifier(RailPanelReordering(panel: panel, order: stack.order, move: move))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func stackHeader(_ panel: RightRailPanel) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Label(panel.title, systemImage: panel.icon)
            Spacer(minLength: 0)
            Button { toggle(panel) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).help("Hide \(panel.title)")
                .accessibilityLabel("Hide \(panel.title)")
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color.appBand)
        .modifier(RailPanelReordering(panel: panel, order: stack.order, move: move))
    }

    // MARK: Tabs

    private func tabBar(_ p: RightRailPrefs.State) -> some View {
        HStack(spacing: 2) {
            tab(.worktree, selected: p.view == .worktree) {
                WorktreeRailAccessory().fixedSize()
            }
            tab(.overview, selected: p.view == .overview) {
                overviewBadge
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Color.appBand)
    }

    private func tab<Badge: View>(_ view: RightRailPrefs.View, selected: Bool,
                                  @ViewBuilder badge: () -> Badge) -> some View {
        let title = view == .worktree ? "Worktree" : "Overview"
        let icon = view == .worktree ? "folder" : "square.grid.2x2"
        return Button {
            show(view == .worktree ? .worktree : (RightRailPanel(rawValue: prefs.queue) ?? .prs))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                badge()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.appSelection : Color.clear))
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help(view == .worktree ? worktreeHelp : "The global queues: Oracles, PRs, Tickets and Chains")
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The checkout Worktree shows, named in the tab's tooltip so the scope is never
    /// a guess; the viewer's own header spells out branch and path.
    private var worktreeHelp: String {
        guard let ctx = model.worktreeContext else { return "The selected session's worktree" }
        let branch = model.folderGitState(ctx.checkout)?.branch
            ?? selectedMeta.flatMap { model.folderGitState($0.cwd)?.branch }
        return "Worktree: \(ctx.checkout)" + (branch.map { " on \($0)" } ?? "")
    }

    /// What across the queues needs you, so Overview says so from the Worktree tab.
    @ViewBuilder private var overviewBadge: some View {
        let n = model.viewerPrQueueTally.actionable + chainsNeedingYou
        if n > 0 {
            Text("\(n)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.22)))
                .foregroundStyle(.orange)
                .help("\(n) waiting on you across PRs and Chains")
        }
    }

    private var chainsNeedingYou: Int {
        model.chains.active.reduce(0) { $0 + model.chainAttention($1).total }
    }

    // MARK: Overview selector

    private func queueSelector(_ p: RightRailPrefs.State, active: RightRailPanel) -> some View {
        let queues = p.order.compactMap(RightRailPanel.init(rawValue:))
        return HStack(spacing: 2) {
            ForEach(queues) { q in
                let selected = q == active
                Button { show(q) } label: {
                    ViewThatFits(in: .horizontal) {
                        selectorLabel(q, selected: selected, titled: true)
                        selectorLabel(q, selected: selected, titled: false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.appSelection : Color.clear))
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help(q.title)
                .accessibilityLabel(q.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func selectorLabel(_ q: RightRailPanel, selected: Bool, titled: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: q.icon).font(.system(size: 10))
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            if titled {
                Text(q.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1).fixedSize()
            }
            count(q)
        }
        .fixedSize()
    }

    /// Actionable counts in orange; totals quiet.
    @ViewBuilder private func count(_ q: RightRailPanel) -> some View {
        switch q {
        case .prs:
            let t = model.viewerPrQueueTally
            if t.actionable > 0 { actionable(t.actionable) } else if t.total > 0 { quiet("\(t.total)") }
        case .chains:
            if chainsNeedingYou > 0 { actionable(chainsNeedingYou) }
            else if !model.chains.active.isEmpty { quiet("\(model.chains.active.count)") }
        case .tickets:
            if !ticketsStore.tickets.isEmpty {
                quiet("\(ticketsStore.tickets.count)\(ticketsStore.hasMore ? "+" : "")")
            }
        case .oracle, .worktree:
            EmptyView()
        }
    }

    private func actionable(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.22)))
            .foregroundStyle(.orange)
    }

    private func quiet(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
    }

    // MARK: Destinations

    @ViewBuilder private func destination(_ panel: RightRailPanel) -> some View {
        switch panel {
        case .worktree:
            VStack(spacing: 0) {
                if model.worktreeContext != nil {
                    WorktreeGitActions(store: gitStore)
                        .padding(.bottom, 2)
                }
                WorktreeRailPanel()
            }
        case .oracle:
            OracleGlobalRail(showsHeader: true)
        case .prs:
            GitHubQueueBadge.GitHubQueuePopover(
                slice: Binding(get: { ViewerPrSlice(storedRaw: filterRaw) },
                               set: { filterRaw = $0.rawValue }),
                showing: .constant(true),
                listMaxHeight: nil,
                revealsSelectedRepo: false)
                // Floored to one search a minute inside `refreshViewerPrs`; the
                // model's own timer keeps it fresh after that.
                .onAppear { model.refreshViewerPrs() }
        case .chains:
            ChainsRailPanel()
        case .tickets:
            LinearTicketsRail(store: ticketsStore, root: root)
        }
    }

    /// A destination going behind another must not keep the keyboard: hand it back
    /// to the terminal if the hidden one held it (a queue's row navigation, or a
    /// Worktree review draft). Skipped while a panel-focus request for the new
    /// destination is pending, so a shortcut that switches and focuses still lands.
    private func releaseKeyboard(leaving old: RightRailPanel, for new: RightRailPanel) {
        if let request = model.panelFocusRequest, request.target.railPanel == new,
           model.consumedPanelFocusSerial != request.serial { return }
        if let target = model.panelNavigation.target, target.railPanel == old {
            model.focusTerminal()
        } else if old == .worktree,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isEditable, !editor.isFieldEditor {
            model.focusTerminal()
        }
    }
}

/// A typed prefix prevents text dragged from a terminal or ticket moving panels.
private struct RailPanelReordering: ViewModifier {
    let panel: RightRailPanel
    let order: [String]
    let move: (RightRailPanel, RightRailPanel) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .draggable("juancode.rail." + panel.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, raw.hasPrefix("juancode.rail."),
                      let source = RightRailPanel(rawValue: String(raw.dropFirst("juancode.rail.".count))),
                      source != panel else { return false }
                move(source, panel)
                return true
            } isTargeted: { targeted = $0 }
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
            }
            .contextMenu {
                if let index = order.firstIndex(of: panel.rawValue) {
                    Button("Move Up") {
                        if index > 0, let previous = RightRailPanel(rawValue: order[index - 1]) { move(panel, previous) }
                    }.disabled(index == 0)
                    Button("Move Down") {
                        if index + 1 < order.count, let next = RightRailPanel(rawValue: order[index + 1]) { move(next, panel) }
                    }.disabled(index == order.count - 1)
                }
            }
    }
}

/// A mounted destination that is not on screen: invisible, out of hit testing and
/// accessibility, and its controls disabled so they cannot take focus.
private struct RailDestinationVisibility: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .disabled(!active)
            .zIndex(active ? 1 : 0)
    }
}

/// Commit, Push and Create PR for the selected session's own checkout, the git
/// writes the retired Diff panel offered. No file watcher: the Worktree viewer owns
/// reading the change, so this only reads the branch state when the checkout or
/// its change signature moves, and after its own writes. Writes go through the
/// selected session (the core's git frames are session-scoped) with `cwd` naming
/// that session's checkout.
@MainActor @Observable
final class WorktreeGitStore {
    struct Note: Equatable { var ok: Bool; var text: String }

    var gitState: GitState?
    var busy = false
    var note: Note?
    @ObservationIgnored private var root: String?

    func refresh(root: String?, model: AppModel) async {
        if root != self.root { note = nil; gitState = nil }
        self.root = root
        guard let root, model.core.unavailableReason(.changes) == nil else { return }
        let state = try? await model.core.gitState(cwd: root)
        // The selection may have moved on while git ran.
        guard root == self.root else { return }
        gitState = state
    }

    /// Stage everything in the checkout and commit it.
    func commit(message: String, model: AppModel) async -> Bool {
        guard let root, let sid = model.selection else { return false }
        busy = true
        defer { busy = false }
        do {
            let r = try await model.core.commitAll(sessionId: sid, cwd: root, message: message)
            note = Note(ok: true, text: "Committed \(r.sha) · \(r.subject)")
            await refresh(root: root, model: model)
            return true
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return false
        }
    }

    func draftMessage(model: AppModel) async -> String? {
        guard let root, let sid = model.selection else { return nil }
        busy = true
        defer { busy = false }
        do {
            return try await model.core.draftCommitMessage(sessionId: sid, cwd: root)
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return nil
        }
    }

    func push(model: AppModel) async {
        guard let root, let sid = model.selection else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await model.core.push(sessionId: sid, cwd: root)
            note = Note(ok: true, text: "Pushed \(r.branch).")
        } catch {
            note = Note(ok: false, text: Self.message(error))
        }
        await refresh(root: root, model: model)
    }

    /// Open a PR for the checkout's branch; gh pushes it first.
    func createPr(title: String, body: String, draft: Bool, model: AppModel) async -> PrCreateResult? {
        guard let root else { return nil }
        guard let reads = model.core.github else {
            note = Note(ok: false, text: model.core.unavailableReason(.github) ?? "This core cannot open pull requests.")
            return nil
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await reads.createPr(cwd: root, title: title, body: body, draft: draft)
            note = Note(ok: true, text: r.created ? "Pull request created." : "A PR already exists for this branch.")
            model.refreshViewerPrs()
            await refresh(root: root, model: model)
            return r
        } catch {
            note = Note(ok: false, text: Self.message(error))
            return nil
        }
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? GitHubError { return e.message }
        if let e = error as? ChangesError { return e.reason }
        return error.localizedDescription
    }
}

/// The Worktree section's git actions bar.
struct WorktreeGitActions: View {
    @Environment(AppModel.self) private var model
    let store: WorktreeGitStore

    @State private var showCommit = false
    @State private var showPr = false
    @State private var message = ""
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = false
    @State private var prResult: PrCreateResult?

    private var state: GitState? { store.gitState }
    private var detached: Bool { state?.detached ?? false }
    private var hasRemote: Bool { state?.remote ?? false }
    /// A PR from the default branch has nothing to merge into; gh would refuse anyway.
    private var onTrunk: Bool { ["main", "master"].contains(state?.branch ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { showCommit.toggle(); showPr = false } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                }
                .popover(isPresented: $showCommit, arrowEdge: .bottom) { commitForm }
                .help("Stage every change in this checkout and commit")

                if (state?.ahead ?? 0) > 0, hasRemote, !detached {
                    Button { Task { await store.push(model: model) } } label: {
                        Label("Push \(state?.ahead ?? 0)", systemImage: "arrow.up.circle")
                    }
                    .disabled(store.busy)
                }

                Button {
                    if prTitle.isEmpty, let b = state?.branch { prTitle = humanizeBranch(b) }
                    showPr.toggle(); showCommit = false
                } label: {
                    Label("Create PR", systemImage: "arrow.triangle.pull")
                }
                .disabled(!hasRemote || detached || onTrunk)
                .popover(isPresented: $showPr, arrowEdge: .bottom) { prForm }
                .help(onTrunk ? "On \(state?.branch ?? "main"): switch to a branch to open a PR"
                      : !hasRemote ? "No remote to open a PR against" : "Push this branch and open a PR")
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 11))
            .clickCursor()

            if let note = store.note {
                Text(note.text)
                    .font(.system(size: 10))
                    .foregroundStyle(note.ok ? .green : .red)
                    .lineLimit(2).help(note.text)
            }
        }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $message)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("✨ Generate") {
                    Task { if let m = await store.draftMessage(model: model) { message = m } }
                }
                .disabled(store.busy)
                .clickCursor()
                Spacer()
                Button("Commit all") {
                    Task {
                        if await store.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                              model: model) {
                            message = ""
                            showCommit = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .clickCursor()
            }
            .controlSize(.small)
            Text("Stages every change (git add -A) then commits on \(state?.branch ?? "the current branch").")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 320)
    }

    private var prForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = prResult {
                Text(r.created ? "Pull request opened." : "A PR already exists for this branch.")
                    .font(.system(size: 12))
                Link(r.url, destination: URL(string: r.url) ?? URL(string: "https://github.com")!)
                    .font(.system(size: 11)).lineLimit(1)
                Button("Done") { prResult = nil; showPr = false }.controlSize(.small).clickCursor()
            } else {
                TextField("PR title", text: $prTitle)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextEditor(text: $prBody)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Toggle("Draft", isOn: $prDraft).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Button("Create PR") {
                        Task {
                            prResult = await store.createPr(title: prTitle, body: prBody,
                                                            draft: prDraft, model: model)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
                }
                .controlSize(.small)
                Text((state?.dirty ?? false)
                     ? "Uncommitted changes stay out of the PR: commit them first."
                     : "Pushes the branch first, then opens the PR.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 320)
    }
}

private struct RailPanelNavigation: ViewModifier {
    let panel: RightRailPanel
    func body(content: Content) -> some View {
        if let target = panel.focusTarget { content.panelNavigation(target) }
        else { content }
    }
}
