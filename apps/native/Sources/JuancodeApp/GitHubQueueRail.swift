// The right rail. Worktree, the selected session's checkout, is anchored at the top
// and follows the selection. Beneath it the global queues (Oracles, PRs, Tickets,
// Chains) keep the user's order and their own state whichever session is selected.
// Every rule about what is open, what takes the space and how stored choices carry
// over lives in `RightRailPrefs.State`; this view draws it and writes it back.
//
// The PR queue was a toolbar badge with the list behind a popover. The rail is always
// on screen, so the queue can be too: the same list, chips and row actions, with no
// click in front of them.

import SwiftUI
import JuancodeCore
import JuancodeClient

enum RightRailPanel: String, CaseIterable, Identifiable {
    case worktree, oracle, prs, tickets, chains
    /// Schema 1's standalone Diff panel; Worktree shows the changes now.
    static var diff: RightRailPanel { .worktree }
    var id: String { rawValue }
    /// Worktree follows the selection and is anchored; the rest are global queues.
    var isGlobal: Bool { self != .worktree }
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

/// Grows a panel body down from its header: the body lays out at full size and the
/// rail only gives it `progress` of that height, so siblings move with the animation.
private struct RailReveal: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .clipped()
            .opacity(progress)
    }
}

private struct RevealLayout: Layout {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let full = child.sizeThatFits(proposal)
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: full.height))
    }
}


struct RightRailPanels: View {
    @Environment(AppModel.self) private var model
    /// Shared with the old popover's key, so the chip you lived on carries over; a
    /// fresh install (nothing stored) opens on what needs you.
    @AppStorage(ViewerPrSlice.storageKey) private var filterRaw: String?
    // Observed so a write from elsewhere (⌘-key shortcuts go through
    // `RightRailPrefs.setOpen`) re-renders the rail. The state itself is read whole
    // through `RightRailPrefs.state`, which tells a key never written from an empty one.
    @AppStorage(RightRailPrefs.orderKey) private var orderRaw = ""
    @AppStorage(RightRailPrefs.collapsedKey) private var collapsedRaw = ""
    @AppStorage(RightRailPrefs.hiddenKey) private var hiddenRaw = ""
    @AppStorage(RightRailPrefs.heightsKey) private var heightsRaw = ""
    @AppStorage(RightRailPrefs.selectedKey) private var selectedRaw = ""
    @AppStorage(RightRailPrefs.pinnedKey) private var pinnedRaw = ""
    @State private var railHeight: CGFloat = 0
    @State private var shownHeight: [RightRailPanel: Double] = [:]
    @State private var overflow: [RightRailPanel: Double] = [:]
    /// Commit / Push / Create PR on the selected checkout. Here so a write's note
    /// outlives a collapse.
    @State private var gitStore = WorktreeGitStore()
    /// Here for the same reason, and so the hourly refresh outlives a collapse.
    @State private var ticketsStore = LinearTicketsStore()
    @State private var dropTarget: RightRailPanel?
    @State private var hoveredHeader: RightRailPanel?
    /// Mirrors the stored strings: an `@AppStorage` write does not reliably carry the
    /// `withAnimation` transaction, so layout reads this until the write lands.
    @State private var mirror: RightRailPrefs.State?
    /// The pencil's mode: every section's header is listed, hidden ones dimmed, each
    /// global with an eye to hide or restore it. Reordering works in both modes.
    @State private var editing = false

    init() {
        // Schema-1 strings (with the retired Diff) are rewritten once, before the
        // first read, so the ⌘-key shortcuts and this view agree from then on.
        RightRailPrefs.migrate(.standard)
    }

    private var prefs: RightRailPrefs.State {
        if let mirror { return mirror }
        // Touch every observed key so a change to any of them re-renders.
        _ = (orderRaw, collapsedRaw, hiddenRaw, heightsRaw, selectedRaw, pinnedRaw)
        return RightRailPrefs.state(RightRailPrefs.Stored(.standard))
    }

    private func apply(_ next: RightRailPrefs.State) {
        mirror = next
        RightRailPrefs.stored(next).write(to: .standard)
    }

    /// The sections with a header on screen: Worktree always, then the globals (all
    /// of them while editing, else the unhidden).
    private func listed(_ p: RightRailPrefs.State) -> [RightRailPanel] {
        let globals = editing ? p.order : p.order.filter { !p.hidden.contains($0) }
        return [.worktree] + globals.compactMap(RightRailPanel.init(rawValue:))
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

    var body: some View {
        let p = prefs
        let listed = listed(p)
        let expanded = p.expanded.compactMap(RightRailPanel.init(rawValue:))
        let anyExpanded = !expanded.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { editing.toggle() }
                } label: {
                    Image(systemName: editing ? "checkmark" : "pencil")
                        .font(.system(size: 12, weight: editing ? .semibold : .regular))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(editing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(editing ? "Done editing panels" : "Show or hide panels")
                .accessibilityLabel(editing ? "Done editing panels" : "Show or hide panels")
                .clickCursor()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { apply(p.settingAllCollapsed(anyExpanded)) }
                } label: {
                    Image(systemName: anyExpanded
                          ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(anyExpanded ? "Collapse all panels" : "Expand panels")
                .accessibilityLabel(anyExpanded ? "Collapse all panels" : "Expand panels")
                .clickCursor()
                .disabled(editing)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            Divider()
            let sized = sizedHeights(expanded, prefs: p, headers: listed.count)
            // Sections keep their place whether collapsed or not: moving a header when
            // it is toggled reads as the rail reshuffling under the cursor.
            ForEach(listed) { panel in
                let isHidden = p.hidden.contains(panel.rawValue)
                let isCollapsed = !p.isOpen(panel.rawValue)
                header(panel, prefs: p, collapsed: isCollapsed, hidden: isHidden)
                if !isCollapsed {
                    // One view for both the sized and the filling case, so a section
                    // becoming the filler resizes rather than being rebuilt.
                    let h = sized[panel]
                    content(panel)
                        .modifier(RailPanelNavigation(panel: panel))
                        .frame(maxWidth: .infinity, minHeight: h ?? 0, maxHeight: h ?? .infinity,
                               alignment: .top)
                        .clipped()
                        .onGeometryChange(for: Double.self) { $0.size.height.rounded() } action: {
                            shownHeight[panel] = $0
                        }
                        .onPreferenceChange(RailOverflowKey.self) { overflow[panel] = $0.map(Double.init) }
                        .overlay(alignment: .bottom) {
                            if let h {
                                DragResizeHandle(axis: .horizontal,
                                                 value: heightBinding(panel, shown: h),
                                                 min: Self.minPanel,
                                                 max: max(Self.minPanel,
                                                          contentSpace(headers: listed.count) - Self.minPanel),
                                                 invert: false,
                                                 showsRailGrip: true)
                                    .offset(y: 7)
                            }
                        }
                        .transition(.modifier(active: RailReveal(progress: 0),
                                              identity: RailReveal(progress: 1)))
                        .zIndex(h == nil ? 0 : 1)
                }
                if panel == .worktree, listed.count > 1 {
                    // Where the selection-scoped section ends and the global queues begin.
                    Rectangle().fill(Color.appHairline(0.18)).frame(height: Self.groupGap)
                        .accessibilityHidden(true)
                }
            }
            if listed.count == 1, !editing {
                Button("Global panels are hidden. Show some…") {
                    withAnimation(.snappy(duration: 0.2)) { editing = true }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(12)
            }
            if !anyExpanded { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railHeight = $0 }
        // A write from anywhere (this view's own included) lands in these keys; drop
        // the mirror so the rail follows the stored state again.
        .onChange(of: [orderRaw, collapsedRaw, hiddenRaw, heightsRaw, selectedRaw, pinnedRaw]) { mirror = nil }
        .background(Color.appSurface)
        // Branch state for the git actions: re-read when the checkout or its change
        // signature moves. The Worktree viewer reads the change itself.
        .task(id: gitRefreshKey) { await gitStore.refresh(root: model.worktreeContext?.checkout, model: model) }
        .task { await ticketsStore.run() }
        // Tickets are project-scoped: the header count follows the selected project
        // even while the Tickets body is collapsed. The global queues do not reset.
        .onChange(of: root, initial: true) { ticketsStore.setRoot(root) }
    }

    private func header(_ panel: RightRailPanel, prefs p: RightRailPrefs.State,
                        collapsed isCollapsed: Bool, hidden isHidden: Bool) -> some View {
        let toggle = {
            withAnimation(.snappy(duration: 0.2)) {
                // A hidden section's header only exists in edit mode; clicking it is
                // asking for it back.
                if isHidden { return apply(p.settingHidden(panel.rawValue, false)) }
                apply(p.toggling(panel.rawValue))
            }
        }
        let isPinned = p.pinned == panel.rawValue
        let canPin = panel.isGlobal && !isCollapsed && p.selected != panel.rawValue
        return HStack(spacing: 5) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: panel.icon).font(.system(size: 10)).foregroundStyle(.tint)
                    Text(panel.title)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase).tracking(0.5)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    if panel != .oracle || editing { Spacer(minLength: 0) }
                }
                .contentShape(Rectangle())
                .opacity(isHidden ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .accessibilityLabel("\(panel.title), \(isHidden ? "hidden" : isCollapsed ? "collapsed" : "expanded")")
            .accessibilityAddTraits(.isHeader)
            if editing {
                if panel.isGlobal {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { apply(p.settingHidden(panel.rawValue, !isHidden)) }
                    } label: {
                        Image(systemName: isHidden ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isHidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .help(isHidden ? "Show \(panel.title)" : "Hide \(panel.title)")
                    .accessibilityLabel(isHidden ? "Show \(panel.title)" : "Hide \(panel.title)")
                    .clickCursor()
                }
            } else {
                switch panel {
                case .oracle: OracleRailAccessory()
                case .worktree: worktreeAccessory
                case .chains: ChainsRailAccessory()
                case .tickets: ticketsPreview
                case .prs: prsPreview
                }
                if canPin && (isPinned || hoveredHeader == panel) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { apply(p.togglingPin(panel.rawValue)) }
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .help(isPinned ? "Unpin \(panel.title)"
                                   : "Pin \(panel.title) open while another panel is open")
                    .accessibilityLabel(isPinned ? "Unpin \(panel.title)" : "Pin \(panel.title) open")
                    .clickCursor()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.headerHeight)
        // The Oracle accessory's spacer sits outside the button, so the gap up to
        // its "+" would otherwise be dead; the whole row toggles.
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .background(Color.appBand)
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.appHairline(0.12)).frame(height: 1)
                Rectangle().fill(Color.accentColor).frame(height: 2)
                    .opacity(dropTarget == panel ? 1 : 0)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .top) {
            // Keep the grip centered within the header's upper inset: even a
            // narrow rail has room here without covering titles or live counts.
            DragGripDots()
            .padding(.top, 3)
            .opacity(panel.isGlobal && hoveredHeader == panel ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onHover { hovering in
            if hovering { hoveredHeader = panel }
            else if hoveredHeader == panel { hoveredHeader = nil }
        }
        .modifier(RailHeaderDrag(panel: panel))
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let dragged = items.first.flatMap(RightRailPanel.init(rawValue:)),
                  dragged.isGlobal, dragged != panel else { return false }
            withAnimation(.snappy(duration: 0.2)) {
                apply(prefs.moving(dragged.rawValue, to: panel.rawValue))
            }
            return true
        } isTargeted: { hovering in
            dropTarget = hovering ? panel : (dropTarget == panel ? nil : dropTarget)
        }
    }

    @ViewBuilder private func content(_ panel: RightRailPanel) -> some View {
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
            OracleGlobalRail(showsHeader: false)
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

    static let headerHeight: CGFloat = 28
    static let groupGap: CGFloat = 3
    static let minPanel: Double = 60
    /// The most a section other than the filler takes before the user sizes it.
    static let unsizedShare = 0.35
    /// The collapse-all bar plus its divider.
    private static let topBarHeight: CGFloat = 27

    /// Height left for section bodies once the bar, the group gap and every listed
    /// header are laid out. Hidden sections have no header outside edit mode.
    private func contentSpace(headers: Int) -> Double {
        let chrome = Self.topBarHeight + Self.groupGap + Self.headerHeight * CGFloat(headers)
        return Double(max(0, railHeight - chrome))
    }

    /// The height that shows a section's whole list, once its scroll view has said
    /// how far short of (or past) that it is.
    private func natural(_ panel: RightRailPanel) -> Double? {
        guard let shown = shownHeight[panel], let over = overflow[panel] else { return nil }
        return max(Self.minPanel, shown + over)
    }

    /// Fixed heights for the open sections other than the filler (the selected one):
    /// the user's size, else the content's up to `unsizedShare` of the rail. The
    /// filler takes what is left; when its own content needs less, it gets that.
    /// Heights that no longer fit are scaled down together so the filler keeps at
    /// least `minPanel`.
    private func sizedHeights(_ expanded: [RightRailPanel], prefs p: RightRailPrefs.State,
                              headers: Int) -> [RightRailPanel: Double] {
        guard let filler = p.filler.flatMap(RightRailPanel.init(rawValue:)), railHeight > 0 else { return [:] }
        let fixed = expanded.filter { $0 != filler }
        let stored = p.heights
        let space = contentSpace(headers: headers)
        let cap = max(Self.minPanel, space * Self.unsizedShare)
        var want = Dictionary(uniqueKeysWithValues: fixed.map { panel in
            (panel, stored[panel.rawValue] ?? min(cap, natural(panel) ?? cap))
        })
        if let own = stored[filler.rawValue] ?? natural(filler), want.values.reduce(0, +) + own <= space {
            want[filler] = own
            return want
        }
        guard !fixed.isEmpty else { return [:] }
        let budget = max(0, space - Self.minPanel)
        let total = want.values.reduce(0, +)
        if total > budget, total > 0 {
            let k = budget / total
            want = want.mapValues { max(min(Self.minPanel, budget / Double(fixed.count)), $0 * k) }
        }
        return want
    }

    private func heightBinding(_ panel: RightRailPanel, shown: Double) -> Binding<Double> {
        Binding(get: { shown }, set: { v in
            var next = prefs
            next.heights[panel.rawValue] = v.rounded()
            apply(next)
        })
    }

    /// The PRs that need you as an accent badge, the rest of the queue as a quiet
    /// total beside it.
    @ViewBuilder private var prsPreview: some View {
        let tally = model.viewerPrQueueTally
        HStack(spacing: 3) {
            if tally.actionable > 0 {
                Text("\(tally.actionable)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                    .foregroundStyle(.orange)
            }
            if tally.quiet > 0 {
                Text("\(tally.actionable > 0 ? "/" : "")\(tally.actionable > 0 ? tally.total : tally.quiet)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .help(tally.actionable > 0
              ? "\(tally.actionable) need\(tally.actionable == 1 ? "s" : "") you of \(tally.total) PRs"
              : "\(tally.total) PRs, none waiting on you")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tally.actionable > 0
                            ? "\(tally.actionable) PRs need you, \(tally.total) total"
                            : "\(tally.total) PRs")
    }

    @ViewBuilder private var ticketsPreview: some View {
        if !ticketsStore.tickets.isEmpty {
            // A total, not a call to action: kept quiet next to the actionable badges.
            Text("\(ticketsStore.tickets.count)\(ticketsStore.hasMore ? "+" : "")")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("\(ticketsStore.tickets.count)\(ticketsStore.hasMore ? "+" : "") tickets")
        }
    }

    /// Which worktree the section is showing, so it is always identifiable, and its
    /// change size while collapsed.
    @ViewBuilder private var worktreeAccessory: some View {
        if let ctx = model.worktreeContext {
            let name = (ctx.checkout as NSString).lastPathComponent
            let branch = model.folderGitState(ctx.checkout)?.branch
                ?? selectedMeta.flatMap { model.folderGitState($0.cwd)?.branch }
            Text(branch.map { "\(name) · \($0)" } ?? name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(branch.map { "\(ctx.checkout) on \($0)" } ?? ctx.checkout)
                .accessibilityLabel("Showing \(name)\(branch.map { " on \($0)" } ?? "")")
            WorktreeRailAccessory().fixedSize()
        } else {
            Text("No session selected")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Only the global queues reorder; Worktree's header is anchored.
private struct RailHeaderDrag: ViewModifier {
    let panel: RightRailPanel
    func body(content: Content) -> some View {
        if panel.isGlobal {
            content
                .draggable(panel.rawValue) {
                    Text(panel.title)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.appSurface.opacity(0.8))
                }
                .help("Drag to reorder")
        } else {
            content
        }
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

/// How much taller a rail panel's list wants to be than it is, negative when it has
/// room to spare. Summed when a panel has more than one list.
struct RailOverflowKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = (value ?? 0) + next }
    }
}

/// Put on a rail panel's ScrollView so the rail can size the panel to its content.
private struct RailOverflowReporter: ViewModifier {
    @State private var overflow: CGFloat?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { g in
                    (g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
                        - g.containerSize.height).rounded()
                } action: { _, v in overflow = v }
                .preference(key: RailOverflowKey.self, value: overflow)
        } else {
            content
        }
    }
}

extension View {
    func reportsRailOverflow() -> some View { modifier(RailOverflowReporter()) }
}

private struct RailPanelNavigation: ViewModifier {
    let panel: RightRailPanel
    func body(content: Content) -> some View {
        if let target = panel.focusTarget { content.panelNavigation(target) }
        else { content }
    }
}
