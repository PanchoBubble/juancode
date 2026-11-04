// The right rail: two full-height views behind a tab bar.
//
// - Worktree: the selected session's checkout (Files/Changes, File/Diff, Expand),
//   with Commit / Push / Create PR on that checkout. Follows the selection.
// - Overview: the global queues. A compact selector picks exactly one of Oracles,
//   PRs, Tickets or Chains, and that queue fills the rest of the rail. The queues
//   do not change with the selection (Tickets aside, which scopes to the project).
//
// Exactly one destination is on screen. The others stay mounted once visited, so
// their scroll position, filters and review drafts survive a switch, but they are
// invisible, take no clicks and give the keyboard back if they held it. Navigation
// state and its migration from the old stacked layout live in `RightRailPrefs`.

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

    var body: some View {
        let p = prefs
        let active = RightRailPanel(rawValue: p.destination) ?? .worktree
        VStack(spacing: 0) {
            tabBar(p)
            Divider()
            if p.view == .overview {
                queueSelector(p, active: active)
                Divider()
            }
            ZStack(alignment: .top) {
                ForEach(RightRailPanel.allCases) { panel in
                    if panel == active || mounted.contains(panel) {
                        destination(panel)
                            .modifier(RailPanelNavigation(panel: panel))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .modifier(RailDestinationVisibility(active: panel == active))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appSurface)
        .onChange(of: active, initial: true) { old, new in
            mounted.insert(new)
            if old != new { releaseKeyboard(leaving: old, for: new) }
        }
        // Branch state for the git actions: re-read when the checkout or its change
        // signature moves. The Worktree viewer reads the change itself.
        .task(id: gitRefreshKey) { await gitStore.refresh(root: model.worktreeContext?.checkout, model: model) }
        .task { await ticketsStore.run() }
        // Tickets are project-scoped: the count follows the selected project even
        // while another destination is up.
        .onChange(of: root, initial: true) { ticketsStore.setRoot(root) }
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
