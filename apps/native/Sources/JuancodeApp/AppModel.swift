import Foundation
import Observation
import AppKit
import SwiftUI
import JuancodeCore
import JuancodeServices
import JuancodePersistence
import JuancodeServer

/// UserDefaults key for the turn-boundary notification toggle (Dock bounce + badge).
private let notifyDefaultsKey = "juancode.notify.turnEnd"

/// UserDefaults key for the outbound notification webhook URL (juancode-xac). Empty
/// = off. POSTed (Slack-compatible JSON) on the same turn-end/needs-input edge.
private let notifyWebhookUrlKey = "juancode.notify.webhookUrl"

/// UserDefaults key for the "keep awake" toggle (block idle system sleep).
private let keepAwakeDefaultsKey = "juancode.keepAwake"

/// UserDefaults key for the idle-session sleep window driving the `SessionReaper`,
/// in minutes (`0` = never / disabled). Key name predates the reaper.
private let autoCloseIdleMinutesKey = "juancode.autoCloseIdleMinutes"

/// UserDefaults key for the user's custom sidebar project (folder) order — cwds.
private let projectOrderKey = "juancode.projectOrder"

/// UserDefaults key for the user's manual within-project session order:
/// project cwd → ordered session ids (a plist-safe [String: [String]]).
private let sessionOrderKey = "juancode.sessionOrder"

/// UserDefaults key for the user's saved custom dev ports in the Kill Port utility
/// (added on top of the built-in suggestions).
private let savedPortsKey = "juancode.killPort.savedPorts"

/// UserDefaults keys for the estimated-cost budget (juancode-qoc): a USD ceiling
/// (`0` = off) and the percent-of-budget at which the total turns amber.
private let costBudgetUsdKey = "juancode.costBudgetUsd"
private let costBudgetWarnPercentKey = "juancode.costBudgetWarnPercent"

/// A resumable external CLI conversation offered in the new-session sheet's
/// "Continue existing" picker (juancode-g4c): a cwd-scoped, header-only
/// `listExternalSessions` hit enriched with a derived display title. Selecting one
/// adopts + resumes it through the T2 path (`adoptExternal`, juancode-iqi).
struct ResumableSession: Identifiable, Sendable {
    let provider: ProviderId
    let cliSessionId: String
    let startMs: Int
    let title: String
    var id: String { cliSessionId }
}

/// Observable view-model bridging the SwiftUI shell to the shared `AppState`. The
/// local UI is an in-process subscriber to the same `SessionRegistry` the
/// embedded server drives — there is no WS hop for the local view.
@MainActor
@Observable
final class AppModel {
    let appState: AppState

    /// Set when the on-disk database failed to open and the app fell back to an
    /// ephemeral in-memory store (juancode-4zk). Non-nil = degraded: nothing this
    /// launch persists. The value is the underlying open error, shown in the
    /// recovery sheet; `corruptDbPath` is the on-disk file the user can reset.
    let degradedReason: String?
    let corruptDbPath: String?

    var sessions: [SessionMeta] = []
    /// Every SessionMeta seen this run, keyed by id and NOT purged by the retention
    /// cap. Lets `reactivate` revive a session whose db row the cap deleted out from
    /// under an open pane — re-inserting from the last-known meta instead of failing
    /// with "not found".
    private var metaCache: [String: SessionMeta] = [:]
    var activities: [String: SessionActivity] = [:]
    var selection: String? {
        didSet {
            // Viewing a session clears its pending turn-end notification (and the
            // Dock badge count it contributed).
            if let sel = selection { clearUnread(sel) }
            // Synchronously, so the pane pool already contains the new selection
            // when SwiftUI renders this switch — the previous pane hides instead
            // of unmounting, and the new one mounts (or is revealed) in the same
            // frame (juancode-073).
            if let sel = selection { noteLivePaneVisible(sel) }
            // Navigating to a session (jump palette, notification click-through,
            // "Go to session", search hits) dismisses the GitHub overlay — every
            // landing path routes through this setter (juancode-2t6).
            showingGitHub = false
        }
    }
    var showingNewSession = false

    /// Sessions whose exited pane is currently being resumed (async `reactivate` in
    /// flight), so the sidebar row can show a spinner instead of the idle dot until
    /// the pty is back. Set/cleared by `openPersistedPane`.
    private(set) var activatingSessions: Set<String> = []
    func isActivating(_ id: String) -> Bool { activatingSessions.contains(id) }

    /// Live window content width, published by `RootView`. Drives the screen-size-
    /// proportional *default* widths of the sidebar / Changes panel / Oracle dock —
    /// only until the user drags a panel edge, after which the persisted manual
    /// width wins (see `PanelAutoSize`).
    var windowWidth: CGFloat = 0

    // MARK: Keyboard navigation (juancode-vgm)
    //
    // Vim-style sidebar nav + ⌃H/⌃L pane focus, driven by a window-scoped NSEvent
    // monitor (see `installPaneNavigation`). The monitor pre-empts the terminal's
    // first responder, so these all work even while a session is focused.

    /// Session IDs in the order they appear in the sidebar, top-to-bottom (folders
    /// flattened, externals excluded). Published by `SidebarView`; drives j/k.
    var navOrder: [String] = []
    /// Bumped to request the live terminal grab focus (Enter / l / ⌃L). Threaded into
    /// `SwiftTermLive.focusToken`.
    var terminalFocusToken = 0
    /// Bumped to request the sidebar list grab focus (⌃H). Drives a `@FocusState`.
    var sidebarFocusToken = 0
    /// Bumped to request the sidebar's "Filter sessions…" field grab focus (⌃F).
    /// Drives a `@FocusState` in `SidebarView`.
    var sessionSearchFocusToken = 0
    /// True while the Changes panel's diff pane owns the keyboard (j/k/n/p/space/v).
    /// The window key monitor bails when set, so the panel's own `.onKeyPress` sees
    /// the plain keys instead of them being swallowed as sidebar nav.
    var changesKeyboardActive = false
    /// A one-shot request for the Changes diff pane to grab keyboard focus, carrying
    /// the session it targets (juancode-qce.3). Only the explicit "open changes" paths
    /// (⌘⇧C, the review badge/banner) set it; a plain panel re-appear (e.g. switching
    /// sessions with the panel open) does NOT, so the diff pane never steals focus from
    /// the terminal on a session switch. The panel consumes and clears it.
    var changesFocusRequest: String?
    /// A one-shot git-action request from the diff pane's single keys (`c` = commit,
    /// shift-P = push+PR). GitActionsView watches it and opens the matching flow for
    /// its session, so acting on a review needs no mouse.
    struct GitFlowRequest: Equatable { let token: Int; let session: String; let flow: GitFlow }
    enum GitFlow: Equatable { case commit, pr }
    private var gitFlowToken = 0
    var gitFlowRequest: GitFlowRequest?

    /// Ask the diff pane for `session` to take keyboard focus on its next appear /
    /// change. Paired with the explicit open paths only.
    func requestChangesFocus(_ session: String) { changesFocusRequest = session }

    /// Fire a commit (`c`) or push+PR (shift-P) flow for `session` from the diff pane.
    func requestGitFlow(_ session: String, _ flow: GitFlow) {
        gitFlowToken &+= 1
        gitFlowRequest = GitFlowRequest(token: gitFlowToken, session: session, flow: flow)
    }
    /// Bumped to request the live terminal re-measure its bounds and force a genuine
    /// SIGWINCH — the manual "recalculate geometry" escape hatch for when a resize
    /// left the pane mis-sized (black margins / clipped render) and the automatic
    /// resync was missed. Threaded into `GhosttyLive`/`SwiftTermLive.resyncToken`.
    var terminalResyncToken = 0
    /// Bumped to force a full terminal repaint: folded into the live terminal view's
    /// SwiftUI `.id`, so a change tears the view down and recreates it, which
    /// re-subscribes with `replay: true` and repaints the whole scrollback from
    /// scratch. The "hard refresh" escape hatch for a pane that's visually corrupted
    /// (garbled glyphs, half-drawn TUI, frozen render) — stronger than a geometry
    /// resync, which only re-asserts the grid size.
    var terminalRefreshToken = 0
    /// Keep-alive pool of main terminal panes (juancode-073): the surfaces of the
    /// most recently viewed live sessions stay MOUNTED (hidden, rendering
    /// suspended) across session switches, so returning to one never replays raw
    /// scrollback — the root of the replay-garble bug class. Capped small: each
    /// mounted pane holds a Metal surface. Evicted panes fall back to
    /// teardown+replay. Rendered by `SessionContainer.terminal` (Ghostty only).
    var livePanes = LivePanePool<Session>(cap: 5)
    /// While true (sidebar is being keyboard-navigated) a freshly-shown terminal must
    /// not auto-grab focus on appear, or each j/k would yank focus back into the pty.
    var suppressTerminalAutoFocus = false
    /// Top command-bar sheets (juancode-6sw / q6q / 38z).
    var showingWorktrees = false
    /// Tracked Linear issues panel (juancode-7sa).
    var showingTrackedIssues = false
    /// First-class GitHub view (juancode-2t6): overlays the detail area with all
    /// open PRs per project. NOT a sheet — the session content stays mounted
    /// underneath (juancode-073); `selection.didSet` auto-dismisses it so every
    /// navigation path lands back on the session.
    var showingGitHub = false
    /// Selection + per-PR detail caches for the GitHub view (see GitHubPanel.swift).
    let github = GitHubModel()
    /// Session-health panel (juancode-0me pillar 3 / juancode-02k).
    var showingSessionHealth = false
    /// Recurring-tasks create/manage panel (juancode-46g).
    var showingRecurringTasks = false
    /// ⌘⇧K prompt-template palette (juancode-2vd): quick-insert saved prompts.
    var showingPromptPalette = false
    /// ⌘K session jump palette (juancode-dr0): fuzzy-find and switch sessions.
    var showingJumpPalette = false
    /// ⌘P Quick Open palette: fuzzy-find a file in the selected session's worktree.
    var showingQuickOpen = false
    /// ⌘F in-pane find bar (juancode-972): search the visible session's scrollback.
    /// Scoped to `selection`; the bar overlays that session's terminal pane.
    var showingFindBar = false
    /// Bumped to (re)focus the find bar's text field — lets a second ⌘F while the
    /// bar is already open pull focus back to it instead of no-opping.
    var findFocusToken = 0
    /// Bumped on a "teleport" landing (⌘K jump palette, notification click-through,
    /// sidebar keyboard-nav open) to flash the visible pane's rim so the eye finds
    /// the right pane (juancode-vz1). NOT bumped on plain mouse clicks or routine
    /// sidebar mouse switching — only the paths where visual context may be lost.
    /// A repeated bump restarts the fade cleanly (see `FocusRimFlash`).
    var focusRimFlashToken = 0
    /// Saved prompt templates, loaded from `UserDefaults` on launch. Mutated through
    /// `addTemplate`/`updateTemplate`/`deleteTemplate`, which persist on every change.
    var promptTemplates: [PromptTemplate] = []
    /// Session presets (juancode-a2r): saved launch configs (agent + folder + knobs
    /// + optional seed prompt) that spawn one or many sessions at once. Mutated
    /// through `addSessionTemplate`/`updateSessionTemplate`/`deleteSessionTemplate`,
    /// which persist on every change. The launcher sheet binds to this array.
    var sessionTemplates: [SessionTemplate] = []
    /// Controls the session-template launcher/manager sheet.
    var showingSessionTemplates = false
    /// Controls the Kill Port utility sheet — find and free a stuck local dev port.
    var showingKillPort = false
    var errorMessage: String?
    /// The file currently open in the floating editor overlay, if any. A single
    /// overlay at a time; hosted at the window root by `EditorHost`.
    var editing: EditorTarget?

    /// Open-PR lists per folder cwd, loaded lazily by `FolderHeader` and refreshed
    /// in the background. Mirrors the web's per-folder `useQuery(["prs", cwd])`.
    var prsByCwd: [String: PrListResult] = [:]
    /// cwds with a PR fetch in flight, so a refresh doesn't stampede.
    private var prsLoading: Set<String> = []
    /// Per-cwd debounce tasks for the PR popover's background scoped re-query.
    private var prsBackfillTasks: [String: Task<Void, Never>] = [:]

    private var activityCancels: [String: () -> Void] = [:]
    private var gridCancels: [String: () -> Void] = [:]
    private var metaCancels: [String: () -> Void] = [:]

    /// Shared FSEvents watchers, one stream per worktree path, so an open Changes
    /// panel refreshes on external edits without a manual Refresh. Consumers (open
    /// panels) hold `changesWatchTokens`; the stream is torn down when the last is
    /// released, so idle CPU stays at zero with many worktrees open.
    private let worktreeWatchers = WorktreeWatcherRegistry()
    /// sessionId → live worktree-watch subscription while its Changes panel is open.
    private var changesWatchTokens: [String: WorktreeWatchToken] = [:]

    /// Latest whole-tree `git status --porcelain` snapshot per worktree path,
    /// refreshed by the watcher. Groundwork for a file-tree sidebar / Quick Open
    /// index; the ChangesPanel itself reads the richer `diffBySession`.
    private(set) var worktreeStatusByPath: [String: [WorktreeStatusEntry]] = [:]

    /// The watched change snapshot for `path` (empty until first refresh).
    func worktreeStatus(_ path: String) -> [WorktreeStatusEntry] {
        worktreeStatusByPath[path] ?? []
    }

    // MARK: - Quick Open file index (juancode-dlr)

    /// Per-worktree `git ls-files` cache backing the ⌘P Quick Open palette, invalidated
    /// by the shared FSEvents watcher. `@ObservationIgnored` — the view observes the
    /// published `quickOpenFiles` snapshot, not the cache.
    @ObservationIgnored private var fileIndex = FileIndex()
    /// worktree path → live watch subscription that invalidates the file index on change.
    @ObservationIgnored private var fileIndexWatchTokens: [String: WorktreeWatchToken] = [:]
    /// The worktree the Quick Open palette is currently indexing.
    private(set) var quickOpenCwd: String?
    /// The file list the palette matches against (cached snapshot for `quickOpenCwd`).
    private(set) var quickOpenFiles: [String] = []
    /// True while a fresh `git ls-files` for the palette is in flight.
    private(set) var quickOpenLoading = false

    // MARK: - File-tree sidebar (Files side-panel tab)

    /// Full worktree file tree per path — the gitignore-aware `git ls-files` listing
    /// folded into nested nodes for the Files tab. Shares the Quick Open `fileIndex`
    /// cache; the shared FSEvents watcher invalidates and rebuilds it live.
    private(set) var fileTreeByPath: [String: [FileTreeNode]] = [:]
    /// Worktree paths with a tree (re)list in flight.
    private(set) var fileTreeLoading: Set<String> = []
    /// Expanded directory ids per worktree path. In-memory only — survives tab and
    /// session switches within a run, resets on relaunch.
    var fileTreeExpandedByPath: [String: Set<String>] = [:]
    /// sessionId → live worktree-watch subscription while its Files tab is open.
    @ObservationIgnored private var fileTreeWatchTokens: [String: WorktreeWatchToken] = [:]

    /// OS-notification plumbing for background sessions (juancode-bao). The
    /// should-notify decision is the pure `agentNotificationEffect`; this only
    /// delivers, coalesces per session, and routes a click back to the session.
    private let agentNotifier = AgentNotifier()

    /// sessionId → remote client id, for sessions whose pty grid a web/phone
    /// viewer currently owns (juancode-2t4). Bridged from `Session.onGridChange`
    /// in `watch` the same way activity edges flow; drives the "remote is
    /// driving" overlay on the visible pane (`RemoteDriveOverlay`). Only remote
    /// owners are recorded — a local claim or a release removes the entry, so
    /// the overlay auto-dismisses the moment this pane re-takes the grid.
    private(set) var remoteGridOwners: [String: String] = [:]

    /// The remote client id driving `id`'s pty grid, or nil when the local pane
    /// owns it / it's unclaimed.
    func remoteGridOwner(_ id: String) -> String? { remoteGridOwners[id] }

    /// sessionId → active "restored from disk" banner phase (juancode-mya), or absent
    /// when hidden. Keyed by id so switching sessions never leaks one pane's banner
    /// onto another; the SwiftUI overlay reads only the visible pane's entry.
    private(set) var restoredBanners: [String: SessionRestoredBanner.Phase] = [:]

    /// Sessions persisted (and not live) at app launch — the disk-restore candidates
    /// whose first auto-revive this run gets the banner. A cold restart empties the
    /// pty registry, so this is every persisted session that isn't already running.
    private let launchRestoredIds: Set<String>

    /// Restore candidates already revived once this run, so re-opening one within the
    /// same run (after it exits again, say) doesn't re-announce a restore.
    private var revivedRestoresThisRun: Set<String> = []

    /// Live-output subscription cancels for restored panes awaiting their first live
    /// byte — the auto-dismiss hook for the `.resuming` banner.
    private var restoreOutputCancels: [String: () -> Void] = [:]

    init(appState: AppState, degradedReason: String? = nil, corruptDbPath: String? = nil) {
        self.appState = appState
        self.degradedReason = degradedReason
        self.corruptDbPath = corruptDbPath
        // Snapshot the disk-restore candidates before anything revives: persisted
        // sessions not already live in the (post-restart, usually empty) registry.
        let liveAtLaunch = Set(appState.registry.all().map(\.id))
        self.launchRestoredIds = Set(appState.store.list().map(\.id)).subtracting(liveAtLaunch)
        appState.registry.onCreate { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.watch(s)
                self.pruneSessionsPerProject()
                self.refresh()
            }
        }
        for s in appState.registry.all() { watch(s) }
        refresh()
        // Route a clicked agent notification back to its session (juancode-bao):
        // activate the app and select that pane (or open the Oracle dock for its
        // sidebar-hidden sessions). Same landing path as the ⌘K jump palette.
        agentNotifier.onSelect = { [weak self] id in
            Task { @MainActor in self?.revealSession(id) }
        }
        agentNotifier.start()
        subscribeTrackedMirror()
        restoreTrackedIssues()
        restoreRecurringTasks()
        restorePromptTemplates()
        restoreSessionTemplates()
        startHealthLoop() // periodic sweep for dead/stale sessions (juancode-0me pillar 3)
        applyReaperWindow() // the user's idle window (not the boot default) drives the reaper
        startWorkAtRiskLoop() // periodic dirty/unpushed scan (juancode-rxu)
        applyKeepAwake() // honour a persisted "keep awake" state on launch
        // Returning to the app clears the badge for whatever session you land on,
        // and marks the desktop active so the phone-push gate stays quiet (juancode-2zp).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appState.markDesktopActive()
                if let sel = self.selection { self.clearUnread(sel) }
            }
        }
        // Stepping away records one final stamp so `lastActiveMs` reflects exactly when
        // the desktop went background (juancode-2zp).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appState.markDesktopActive() }
        }
        // Seed presence at launch when the app starts frontmost (the usual case: the
        // AppDelegate promotes to a regular foreground app and activates). `NSApp` is
        // still nil this early in `App.main()`, so chain optionally — if it's not up
        // yet the didBecomeActive observer above stamps presence the moment it is.
        if NSApp?.isActive == true { appState.markDesktopActive() }
    }

    // MARK: - Turn-end notifications (Dock bounce + unread badge)

    /// Sessions that finished a turn (or now need input) while you weren't watching
    /// them. Their count drives the Dock badge; clearing happens when you view the
    /// session or return to the app.
    private(set) var unreadSessions: Set<String> = []

    /// Sessions whose agent finished a turn (busy → idle) while they weren't the
    /// current selection — drives the sidebar's green "done since you last looked"
    /// check (juancode-t9p). Cleared through the same choke point as unread
    /// (`clearUnread`: selection, app re-activation, delete) and when a new turn
    /// starts. Deliberately independent of `notifyOnTurnEnd`: muting Dock bounces
    /// shouldn't hide the sidebar state vocabulary.
    private(set) var unseenCompletions: Set<String> = []

    /// Whether the Oracle dock is currently expanded. Oracle's own sessions are hidden
    /// from the sidebar, so their unread can never clear by selection (the Dock badge
    /// would stay stuck). Instead the dock acts as their "viewer": while it's open we
    /// suppress + clear their notifications, mirroring how selecting a session clears it.
    var oracleDockExpanded = false {
        didSet { if oracleDockExpanded { markOracleRead() } }
    }

    /// Unread sessions surfaced in the notification list / bell — excludes Oracle's own
    /// sessions (handled by the dock) since they aren't selectable from the sidebar.
    var unreadSessionMetas: [SessionMeta] {
        sessions.filter { unreadSessions.contains($0.id) && $0.cwd != OraclePaths.controlDir }
    }

    private func clearUnread(_ id: String) {
        unseenCompletions.remove(id)
        // Drop any lingering OS notification so a seen session doesn't leave a stale
        // ding in Notification Center (juancode-bao).
        agentNotifier.clear(sessionId: id)
        guard unreadSessions.remove(id) != nil else { return }
        updateDockBadge()
    }

    /// Is this one of Oracle's own sessions (rooted in its control dir)?
    private func isOracleSession(_ id: String) -> Bool {
        (liveSession(id)?.meta.cwd ?? sessions.first { $0.id == id }?.cwd) == OraclePaths.controlDir
    }

    /// Clear any pending unread for every live/known Oracle session — called when the
    /// Oracle dock is opened (its sessions are never the sidebar `selection`).
    private func markOracleRead() {
        for id in unreadSessions where isOracleSession(id) { clearUnread(id) }
    }

    /// Reflect the unread count on the Dock tile — a number badge, hidden at zero.
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unreadSessions.isEmpty ? nil : "\(unreadSessions.count)"
    }

    /// Persisted sessions (incl. exited), with live registry meta preferred for
    /// running ones so status/title/usage reflect the live pty.
    func refresh() {
        let persisted = appState.store.list()
        let liveSessions = appState.registry.all()
        let live = Dictionary(liveSessions.map { ($0.id, $0.meta) }, uniquingKeysWith: { a, _ in a })
        var merged = persisted.map { live[$0.id] ?? $0 }
        // Live sessions the store doesn't hold — editor sessions aren't persisted
        // (see `SessionKind.editor`) yet must still show in the sidebar while open.
        let persistedIds = Set(persisted.map(\.id))
        merged.append(contentsOf: liveSessions.map(\.meta).filter { !persistedIds.contains($0.id) })
        sessions = merged
        for m in sessions { metaCache[m.id] = m }
        // Every registry change routes through here (create / exit / swap), so this
        // is where pooled keep-alive panes whose session died or was replaced get
        // unmounted rather than lingering hidden on a dead pty subscription.
        livePanes.prune { [appState] in appState.registry.get($0) }
        refreshWorktreeMap()
    }

    /// Apply a single live session's meta change (title/usage poll, rename, archive)
    /// in place instead of rebuilding the whole list from `store.list()` — so
    /// SwiftUI re-renders only the changed row (juancode-5qw.8). The incoming `meta`
    /// is the live registry meta `refresh()` would itself prefer, so patching with
    /// it matches a full rebuild without the DB round-trip, prune, or worktree scan.
    /// Falls back to a full `refresh()` when the id isn't in the current list yet
    /// (an unseen create/adopt — create/exit/adopt keep the full path).
    func applyMetaPatch(_ meta: SessionMeta) {
        switch metaPatchOutcome(for: meta, in: sessions) {
        case .patch(let idx):
            sessions[idx] = meta
            metaCache[meta.id] = meta
        case .noChange:
            break
        case .fullRefresh:
            refresh()
        }
    }

    /// Enforce the per-project session retention cap (juancode-477): hard-delete the
    /// oldest persisted sessions once a project exceeds `Config.sessionsPerProjectCap`.
    /// Uses the runtime worktree→repo map (same folding as the sidebar) so linked
    /// worktrees share their repo's cap, and never prunes a live pty, the session
    /// currently selected, or one whose pane is mid-resume — so an exited session you
    /// have open can't be deleted out from under its pane.
    private func pruneSessionsPerProject() {
        var keep = Set(appState.registry.all().map(\.id))
        if let sel = selection { keep.insert(sel) }
        keep.formUnion(activatingSessions)
        let repoRoots = worktreeRepoRoots
        appState.store.enforceSessionCap(
            projectKey: { repoRoots[$0] ?? projectCwd(for: $0) },
            keepIds: keep
        )
    }

    // MARK: - Worktree → repo grouping

    /// Authoritative map from any git worktree path to its repo's main worktree
    /// path, so the sidebar nests linked worktrees under their project — even ones
    /// whose dir doesn't follow the `<repo>-worktrees/` naming (a plain
    /// `git worktree add ../styx`). Built by shelling `git worktree list` per
    /// distinct session cwd; populated async, so grouping refines once it lands.
    var worktreeRepoRoots: [String: String] = [:]
    /// cwds already scanned (incl. non-git ones that returned nothing) so we don't
    /// re-shell git for them on every refresh.
    private var scannedWorktreeCwds: Set<String> = []
    private var worktreeScanInFlight = false

    /// Scan any not-yet-seen session cwd for its repo's worktrees and record each
    /// `worktree → main` mapping. Cached + guarded so refresh() can call it freely.
    func refreshWorktreeMap() {
        let cwds = Set(sessions.map(\.cwd) + sessions.compactMap(\.worktreePath))
            .subtracting(scannedWorktreeCwds)
        guard !cwds.isEmpty, !worktreeScanInFlight else { return }
        worktreeScanInFlight = true
        Task {
            var additions: [String: String] = [:]
            for cwd in cwds {
                let trees = await Task.detached(priority: .utility) { await listWorktrees(cwd) }.value
                guard let main = trees.first(where: { $0.main }) else { continue }
                for t in trees { additions[t.path] = main.path }
            }
            for (k, v) in additions { worktreeRepoRoots[k] = v }
            scannedWorktreeCwds.formUnion(cwds)
            worktreeScanInFlight = false
            // New sessions may have arrived mid-scan; pick them up (no-op if none).
            refreshWorktreeMap()
        }
    }

    func activity(_ id: String) -> SessionActivity? { activities[id] }

    func isLive(_ id: String) -> Bool { appState.registry.get(id) != nil }

    func liveSession(_ id: String) -> Session? { appState.registry.get(id) }

    /// Move the sidebar selection by `delta` rows within `navOrder` (clamped). With
    /// nothing selected, jumps to the first (down) or last (up) row.
    func moveSelection(by delta: Int) {
        guard !navOrder.isEmpty else { return }
        if let cur = selection, let idx = navOrder.firstIndex(of: cur) {
            selection = navOrder[max(0, min(navOrder.count - 1, idx + delta))]
        } else {
            selection = delta >= 0 ? navOrder.first : navOrder.last
        }
    }

    func selectFirst() { if let f = navOrder.first { selection = f } }
    func selectLast() { if let l = navOrder.last { selection = l } }

    /// Move keyboard focus to the sidebar (⌃H): suppress terminal auto-focus so j/k
    /// don't bounce focus back into the pty, and nudge the list to become first responder.
    func focusSidebar() {
        suppressTerminalAutoFocus = true
        if selection == nil { selectFirst() }
        sidebarFocusToken &+= 1
    }

    /// Move keyboard focus to the sidebar's session filter field (⌃F), so you can
    /// start typing a find query without reaching for the mouse.
    func focusSessionSearch() {
        suppressTerminalAutoFocus = true
        sessionSearchFocusToken &+= 1
    }

    /// Move keyboard focus into the live terminal (Enter / l / ⌃L).
    func focusTerminal() {
        suppressTerminalAutoFocus = false
        terminalFocusToken &+= 1
    }

    /// Flash the visible pane's rim (juancode-vz1). Called from the teleport paths
    /// only — the ⌘K jump palette, a clicked notification's `revealSession`, and the
    /// sidebar keyboard-nav open — so the eye lands on the pane the jump chose. Each
    /// call restarts the fade from full opacity (see `FocusRimFlash`).
    func flashFocusRim() {
        focusRimFlashToken &+= 1
    }

    /// Open (or refocus) the in-pane find bar over the visible session (⌘F,
    /// juancode-972). Idempotent when already open — the token bump pulls focus
    /// back to the field so a repeat ⌘F re-arms it.
    func showFindBar() {
        showingFindBar = true
        findFocusToken &+= 1
    }

    /// Close the find bar and return keyboard focus to the terminal (Esc).
    func closeFindBar() {
        guard showingFindBar else { return }
        showingFindBar = false
        focusTerminal()
    }

    /// Manually re-measure the live terminal and force a SIGWINCH — recovers a pane
    /// left mis-sized by a resize the automatic resync missed. Wired to the toolbar
    /// and the View menu (⌃⇧R).
    func resyncTerminalGeometry() {
        terminalResyncToken &+= 1
    }

    /// Hard-refresh the live terminal: rebuild the view so it replays the full
    /// scrollback and repaints cleanly. Recovers a pane whose render is corrupted
    /// (garbled glyphs / half-drawn TUI) — a geometry resync can't fix that.
    ///
    /// The replay alone can't heal the visible screen: scrollback is raw bytes
    /// recorded at whatever widths the session lived through, so after a resize
    /// the tail re-renders just as mis-wrapped — and re-sending an unchanged grid
    /// is a no-op SIGWINCH the CLI never hears, so it never repaints ("refresh
    /// just breaks it"). Chase the replay with a geometry resync — a genuine
    /// SIGWINCH — so the CLI redraws the live screen at the current grid; history
    /// above stays best-effort. Delayed because the recreated view seeds its
    /// resync-token cache at creation: a bump before it exists is invisible, so
    /// wait out view recreation + surface attach + replay.
    func refreshTerminal() {
        terminalRefreshToken &+= 1
        // Re-key only the visible pooled pane: its SwiftUI identity folds the
        // token, so the bump recreates just that pane (fresh subscribe + full
        // replay) while the hidden keep-alive panes stay mounted untouched.
        if let sel = selection { livePanes.bumpRefresh(sel, to: terminalRefreshToken) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.terminalResyncToken &+= 1
        }
    }

    /// The detail view is showing session `id` live: make sure the keep-alive pane
    /// pool has its entry at the MRU front (juancode-073). Called synchronously
    /// from the `selection` setter for ordinary switches, and again from the
    /// detail view once a reactivation or a permissions flip mints a new live
    /// `Session` behind the same id.
    func noteLivePaneVisible(_ id: String) {
        livePanes.noteVisible(id, refresh: terminalRefreshToken) { [appState] in
            appState.registry.get($0)
        }
    }

    /// Whether the projects (sessions-by-folder) sidebar column is visible. RootView
    /// binds NavigationSplitView's columnVisibility to this, so the ⌃S shortcut can
    /// show/hide it programmatically while the native toolbar toggle stays in sync.
    /// The didSet is the one choke point both paths share: NavigationSplitView
    /// animates the collapse, bursting intermediate grids into the terminal resize
    /// path, so mark it a layout transition — the coordinators hold the intermediate
    /// grids and settle once. 500ms spans the split-view slide plus both settle
    /// windows, matching the bottom-terminal toggle.
    var projectsSidebarVisible = true {
        didSet {
            guard oldValue != projectsSidebarVisible else { return }
            LayoutTransitionGate.shared.begin(for: .milliseconds(500))
        }
    }

    func toggleProjectsSidebar() {
        projectsSidebarVisible.toggle()
    }

    /// Toggle the session's right-side panel onto the Changes tab (⌘C). The panel's
    /// visibility + tab live in @AppStorage inside SessionContainer; writing the same
    /// UserDefaults keys keeps that view the single owner of the state. Hides only
    /// when Changes is already the visible tab — from Issues it switches tabs instead.
    func toggleChangesPanel() {
        let d = UserDefaults.standard
        let shown = d.object(forKey: "session.sidePanel.shown") as? Bool ?? true
        let onChanges = (d.string(forKey: "session.sidePanel.tab") ?? "Changes") == "Changes"
        if shown && onChanges {
            d.set(false, forKey: "session.sidePanel.shown")
        } else {
            d.set("Changes", forKey: "session.sidePanel.tab")
            d.set(true, forKey: "session.sidePanel.shown")
        }
    }

    func scrollback(_ id: String) -> [UInt8] {
        appState.registry.get(id)?.getScrollback() ?? appState.store.getScrollback(id) ?? []
    }

    private func watch(_ s: Session) {
        activities[s.id] = s.activity
        // Editor sessions (nvim etc.) aren't agent turns — their screen churn must
        // never ding a notification, bump the Dock badge, or set the sidebar's
        // "done" check. Their activity is still tracked for the spinner.
        let isEditor = s.meta.kind == .editor
        activityCancels[s.id]?()
        activityCancels[s.id] = s.onActivity { [weak self] st, notify in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.activities[s.id]
                self.activities[s.id] = st
                if isEditor { return }
                // Sidebar "done since you last looked" check (juancode-t9p): set on
                // a turn finishing off-screen, dropped when a new turn starts.
                switch unseenCompletionEffect(prev: prev, next: st, notify: notify,
                                              isSelected: self.selection == s.id) {
                case .set: self.unseenCompletions.insert(s.id)
                case .clear: self.unseenCompletions.remove(s.id)
                case .none: break
                }
                // `notify` marks a real turn boundary (the agent finished or now
                // needs you). Bounce the Dock + bump the badge so background work is
                // noticeable. See `notifyTurnEnd`.
                if notify { self.notifyTurnEnd(sessionId: s.id, state: st) }
                // Same edge, off-device surfacing: an OS notification for a session
                // that isn't the one you're watching (juancode-bao). The pure
                // `agentNotificationEffect` owns the suppression (watched session,
                // teardown resets, non-boundary edges).
                if let kind = agentNotificationEffect(
                    prev: prev, next: st, notify: notify,
                    isSelected: self.selection == s.id, appActive: NSApp.isActive) {
                    self.postAgentNotification(sessionId: s.id, kind: kind)
                }
                // The agent stays `busy` through a turn (including any file edits) and
                // flips to idle / waiting-input when it finishes — so a busy → non-busy
                // transition is the moment the working tree has settled. Re-diff then so
                // the Changes panel reflects the agent's edits without a manual Refresh.
                // Scoped to sessions whose diff is already cached (panel has been opened)
                // or the selected one, to avoid shelling out to git for every background
                // session on every turn.
                if prev == .busy, st != .busy,
                   self.diffBySession[s.id] != nil || self.selection == s.id {
                    self.loadChanges(s.id)
                }
                // Review nudge: on that same settle edge, compute a cheap change
                // summary for every agent session so a dirty tree surfaces a badge
                // (sidebar) + banner even for background work no panel has opened.
                if shouldComputeChangeBadge(prev: prev, next: st, notify: notify, isEditor: isEditor) {
                    self.refreshChangeStat(s.id)
                }
            }
        }
        s.onExit { [weak self] _ in Task { @MainActor in self?.refresh() } }
        // A CLI-derived title / usage landing from the title poll (or a rename /
        // archive) mutates the live meta without a turn edge. Patch that one row in
        // place rather than rebuilding the whole list from `store.list()` every 4s
        // per running session (juancode-5qw.8) — so the sidebar leaves the
        // "Claude Code · <project>" fallback without re-deriving every row.
        metaCancels[s.id]?()
        metaCancels[s.id] = s.onMetaChange { [weak self] meta in
            Task { @MainActor in self?.applyMetaPatch(meta) }
        }
        // Grid-ownership bridge (juancode-2t4): seed from the current owner (a
        // remote may already be driving when this model attaches — app relaunch
        // while a phone viewer holds the grid), then follow arbitrated changes.
        // The listener fires on the resizing client's queue; hop to main.
        gridCancels[s.id]?()
        setRemoteGridOwner(s.id, gridOwner: s.gridOwner())
        gridCancels[s.id] = s.onGridChange { [weak self] owner, _, _ in
            Task { @MainActor in self?.setRemoteGridOwner(s.id, gridOwner: owner) }
        }
    }

    private func setRemoteGridOwner(_ id: String, gridOwner: String?) {
        if let remote = RemoteDriveBadge.remoteOwner(from: gridOwner) {
            remoteGridOwners[id] = remote
        } else {
            remoteGridOwners.removeValue(forKey: id)
        }
    }

    /// Whether a session reaching a turn boundary notifies you (Dock bounce + badge).
    /// Persisted; on by default. Toggle from the View menu (or `defaults write`).
    var notifyOnTurnEnd: Bool = UserDefaults.standard.object(forKey: notifyDefaultsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnTurnEnd, forKey: notifyDefaultsKey) }
    }

    /// Outbound notification webhook URL (juancode-xac). When set, a turn-end /
    /// needs-input event POSTs a Slack-compatible JSON body here so background work
    /// reaches you off-device. Empty = off. Nothing is ever sent without this URL.
    /// Persisted; edited from Settings → Sessions.
    var notifyWebhookUrl: String = UserDefaults.standard.string(forKey: notifyWebhookUrlKey) ?? "" {
        didSet { UserDefaults.standard.set(notifyWebhookUrl, forKey: notifyWebhookUrlKey) }
    }

    /// Light / dark / follow-system appearance (juancode light/dark toggle). Persisted;
    /// drives the SwiftUI `preferredColorScheme` (RootView) and the AppKit window chrome
    /// (`applyAppearance`). Defaults to dark to preserve the app's pure-black look.
    var themePreference: ThemePreference = .persisted {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: ThemePreference.defaultsKey)
            applyAppearance()
        }
    }

    /// Push `themePreference` to the AppKit layer (title bar, menus, scrollers). The
    /// SwiftUI content tree follows via RootView's `preferredColorScheme`. `nil`
    /// appearance means "follow the system" (the `.system` choice).
    func applyAppearance() {
        NSApp.appearance = themePreference.nsAppearance
    }

    /// While on, hold a power assertion that blocks the Mac from idle-sleeping, so a
    /// long-running prompt isn't cut off when you step away (the app already opts out
    /// of App Nap in `AppDelegate`, but that variant still permits idle system sleep —
    /// this is the stronger, user-controlled version). Persisted; on by default so a
    /// walked-away Mac never idle-sleeps mid-prompt unless you opt out.
    /// Toggle from the top toolbar (cup, next to the bell) or the View menu (⌃⇧A).
    var keepAwake: Bool = (UserDefaults.standard.object(forKey: keepAwakeDefaultsKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: keepAwakeDefaultsKey)
            applyKeepAwake()
        }
    }

    /// The held idle-sleep assertion, when `keepAwake` is on. `nil` means the Mac is
    /// free to idle-sleep as usual.
    @ObservationIgnored private var keepAwakeToken: NSObjectProtocol?

    /// Acquire or release the idle-system-sleep assertion to match `keepAwake`.
    /// Idempotent: re-applying the current state is a no-op.
    private func applyKeepAwake() {
        if keepAwake {
            guard keepAwakeToken == nil else { return }
            keepAwakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Keep Awake: running prompts must not be interrupted by sleep")
        } else if let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }

    /// Idle window (minutes) after which the `SessionReaper` puts a session to
    /// sleep: it kills the CLI process tree to free RAM once the session has been
    /// *verifiably* idle for this long, leaving a dormant, resumable tile. `0`
    /// means never — reaping is off. Persisted and edited from Settings → Sessions
    /// (⌘,); pushed into the reaper live via `applyReaperWindow`.
    var autoCloseIdleMinutes: Int = UserDefaults.standard.object(forKey: autoCloseIdleMinutesKey) as? Int ?? 60 {
        didSet {
            UserDefaults.standard.set(autoCloseIdleMinutes, forKey: autoCloseIdleMinutesKey)
            applyReaperWindow()
        }
    }

    /// Push the effective idle window into the reaper. `JUANCODE_REAP_IDLE_MINUTES`
    /// wins when set (the usual env-beats-config precedence); otherwise the user's
    /// Settings value rules, including `0` = disabled.
    private func applyReaperWindow() {
        let minutes = Config.reapIdleMinutesOverride ?? autoCloseIdleMinutes
        Task { [appState] in await appState.sessionReaper.setIdleWindow(minutes: minutes) }
    }

    /// Estimated-cost budget in USD (juancode-qoc). `0` = off. When set, the sidebar
    /// total turns amber past the warn threshold and red at/over budget. Compared
    /// against summed `SessionUsage.costUsd`. Persisted; edited from Settings → Sessions.
    var costBudgetUsd: Double = UserDefaults.standard.object(forKey: costBudgetUsdKey) as? Double ?? 0 {
        didSet { UserDefaults.standard.set(costBudgetUsd, forKey: costBudgetUsdKey) }
    }
    /// Percent-of-budget at which the total goes amber (default 80). Persisted.
    var costBudgetWarnPercent: Int = UserDefaults.standard.object(forKey: costBudgetWarnPercentKey) as? Int ?? 80 {
        didSet { UserDefaults.standard.set(costBudgetWarnPercent, forKey: costBudgetWarnPercentKey) }
    }

    /// Evaluate a spend figure against the current budget (juancode-qoc). `.off`
    /// when no budget is set. Used by the sidebar total footer.
    func budgetStatus(forSpend spentUsd: Double?) -> BudgetStatus {
        evaluateBudget(spentUsd: spentUsd, budgetUsd: costBudgetUsd, warnPercent: costBudgetWarnPercent)
    }

    /// User's custom sidebar project order (folder cwds). Folders not listed here
    /// fall back to alphabetical, after the ordered ones. Persisted; driven by
    /// drag-and-drop on the folder headers.
    var projectOrder: [String] = (UserDefaults.standard.array(forKey: projectOrderKey) as? [String]) ?? [] {
        didSet { UserDefaults.standard.set(projectOrder, forKey: projectOrderKey) }
    }

    /// User's manual within-project session order: project cwd → ordered session
    /// ids. Sessions not listed rest where the default sort puts them; sessions
    /// needing attention bubble above this order temporarily without rewriting it
    /// (see `manualWithBubblePrecedes`). Persisted; driven by drag-and-drop on
    /// the sidebar's session rows.
    var sessionOrder: [String: [String]] = (UserDefaults.standard.dictionary(forKey: sessionOrderKey) as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(sessionOrder, forKey: sessionOrderKey) }
    }

    /// Persist a new manual order for one project, pruning ids of deleted
    /// sessions (and emptied projects) across the whole blob while we're writing.
    func setSessionOrder(_ ids: [String], forProject cwd: String) {
        var next = sessionOrder
        next[cwd] = ids
        let valid = Set((sessions + externalSessions).map(\.id))
        sessionOrder = prunedSessionOrder(next, keeping: valid)
    }

    /// Custom dev ports the user saved in the Kill Port utility, added on top of the
    /// built-in suggestions. Persisted; kept sorted and unique.
    var savedPorts: [Int] = (UserDefaults.standard.array(forKey: savedPortsKey) as? [Int]) ?? [] {
        didSet { UserDefaults.standard.set(savedPorts, forKey: savedPortsKey) }
    }

    /// Save a custom port (no-op if out of range or already saved/suggested).
    func addSavedPort(_ port: Int) {
        guard (1...65535).contains(port), !savedPorts.contains(port) else { return }
        savedPorts = (savedPorts + [port]).sorted()
    }

    /// Forget a saved custom port.
    func removeSavedPort(_ port: Int) {
        savedPorts.removeAll { $0 == port }
    }

    /// At a turn boundary — background work finishing or now needing your reply —
    /// bounce the Dock icon and bump the unread badge count instead of chiming.
    /// `.criticalRequest` bounces until you focus the app (the agent is blocked on
    /// you); `.informationalRequest` bounces once (it's just done). Skipped for the
    /// one session you're already watching (app frontmost + selected).
    private func notifyTurnEnd(sessionId: String, state: SessionActivity) {
        guard notifyOnTurnEnd else { return }
        if NSApp.isActive, selection == sessionId { return }
        // The open Oracle dock is the "viewer" for Oracle's own (sidebar-hidden)
        // sessions — don't accrue an unclearable unread while you're looking at it.
        if NSApp.isActive, oracleDockExpanded, isOracleSession(sessionId) { return }
        unreadSessions.insert(sessionId)
        updateDockBadge()
        NSApp.requestUserAttention(state == .waitingInput ? .criticalRequest : .informationalRequest)
        fireNotificationWebhook(sessionId: sessionId, state: state)
    }

    /// Deliver (or replace) the OS notification for a background session at a turn
    /// boundary (juancode-bao). Whether to fire at all is already decided by
    /// `agentNotificationEffect` at the call site; this only builds the copy, applies
    /// the same global mute (`notifyOnTurnEnd`) and Oracle-dock suppression the Dock
    /// bounce respects, and hands off to the thin `AgentNotifier`.
    private func postAgentNotification(sessionId: String, kind: AgentNotificationKind) {
        guard notifyOnTurnEnd else { return }
        // The open Oracle dock is the "viewer" for Oracle's own (sidebar-hidden)
        // sessions — mirror `notifyTurnEnd`'s suppression.
        if NSApp.isActive, oracleDockExpanded, isOracleSession(sessionId) { return }
        let meta = (sessions + externalSessions).first { $0.id == sessionId }
        let folder = meta.map { ($0.cwd as NSString).lastPathComponent } ?? ""
        agentNotifier.post(
            sessionId: sessionId,
            title: meta?.title ?? "Agent",
            subtitle: folder,
            body: kind == .waitingForInput ? "Waiting for your input" : "Finished a turn",
            critical: kind == .waitingForInput)
    }

    /// Land on the session a clicked notification points at (juancode-bao): bring the
    /// app forward and select that pane, or open the Oracle dock for its own
    /// sidebar-hidden sessions. Selection clears the pending unread + OS notification
    /// through `clearUnread`.
    func revealSession(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if isOracleSession(id) {
            oracleDockExpanded = true
        } else {
            selection = id
            flashFocusRim() // land the eye on the pane the notification pointed at
        }
    }

    /// POST a Slack-compatible notification to the user's configured webhook, if any
    /// (juancode-xac). Fired on the same turn-end/needs-input edge as the Dock
    /// bounce, so it respects the same "not the session you're watching" suppression.
    /// Best-effort and fire-and-forget — a webhook failure never touches the UI.
    private func fireNotificationWebhook(sessionId: String, state: SessionActivity) {
        let meta = (sessions + externalSessions).first { $0.id == sessionId }
        postNotificationWebhook(event: state == .waitingInput ? .waitingInput : .turnEnd,
                                title: meta?.title ?? "", sessionId: sessionId, cwd: meta?.cwd ?? "")
    }

    /// The shared webhook POST: build the body and fire-and-forget it at the
    /// configured URL (no-op when none is set). Used by turn-end and work-at-risk.
    private func postNotificationWebhook(event: NotificationEvent, title: String,
                                         sessionId: String, cwd: String) {
        let raw = notifyWebhookUrl.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = webhookBody(event: event, title: title, sessionId: sessionId, cwd: cwd)
        req.timeoutInterval = 10
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }

    /// The most recently-created live session rooted in `cwd`, if any. Used to find
    /// the pinned Oracle agent session by its unique control-dir cwd.
    func liveSession(inCwd cwd: String) -> Session? {
        appState.registry.all()
            .filter { $0.meta.cwd == cwd }
            .max { $0.meta.createdAt < $1.meta.createdAt }
    }

    /// All persisted (incl. exited) sessions rooted in `cwd`. Used to find/clean up
    /// the pinned Oracle agent's prior sessions.
    func persistedSessions(inCwd cwd: String) -> [SessionMeta] {
        appState.store.list().filter { $0.cwd == cwd }
    }

    @discardableResult
    func create(provider: ProviderId, cwd: String, skipPermissions: Bool,
                isolateWorktree: Bool, initialInput: String? = nil, select: Bool = false,
                cols: Int? = nil, rows: Int? = nil, model: String? = nil,
                worktreeName: String? = nil) async -> Session? {
        do {
            var workCwd = cwd
            var worktreePath: String? = nil
            if isolateWorktree {
                let name = worktreeName ?? String(UUID().uuidString.prefix(8)).lowercased()
                let wt = try await createWorktree(cwd, name)
                workCwd = wt.path
                worktreePath = wt.path
            }
            // Spawn off the main actor: this resolves the CLI via a login shell and
            // forkpty()s — work that must never block the UI run loop.
            let state = appState
            let cwdToUse = workCwd
            let wt = worktreePath
            // Spawn at the given size, else the last on-screen terminal size, so the
            // CLI's alt-screen boots matching the view it'll render in (fixes "fresh
            // session opens short" / the Oracle dock garble). Oracle passes its dock
            // size explicitly since the dock is narrower than the main window.
            let grid: (cols: Int, rows: Int) = (cols != nil && rows != nil) ? (cols!, rows!) : TerminalGrid.spawn
            let s = try await Task.detached(priority: .userInitiated) {
                try state.registry.create(
                    provider: provider, cwd: cwdToUse, cols: grid.cols, rows: grid.rows,
                    opts: SpawnOptions(skipPermissions: skipPermissions, model: model), worktreePath: wt)
            }.value
            // Seed the session with an initial prompt once its TUI is up — the same
            // mechanism the WS `.create` path uses (Session.autoSubmit). Surface a
            // delivery failure instead of leaving the session silently idle with an
            // unsent prompt (the dispatch-loop bug we're guarding against).
            if let initialInput, !initialInput.isEmpty {
                let title = s.meta.title
                s.autoSubmit(initialInput) { [weak self] outcome in
                    guard case .failed(let reason) = outcome else { return }
                    Task { @MainActor in
                        self?.errorMessage = "Couldn't deliver the prompt to \(title): \(reason)"
                    }
                }
            }
            refresh()
            if select {
                selection = s.id
                // Creating a session is an explicit "take me there": clear any j/k
                // nav focus suppression and request focus, so the fresh terminal is
                // typeable whether it appeared behind the New Session sheet, from
                // the folder "+" popover, or mid keyboard navigation.
                focusTerminal()
            }
            return s
        } catch {
            errorMessage = "Failed to start \(provider.rawValue): \(error)"
            return nil
        }
    }

    /// Fan one opening prompt across `count` parallel sessions, each in its OWN fresh
    /// git worktree, so their results can be compared side by side (the "Parallel
    /// Worktrees" flow). Every variant shares a random branch stem with a distinct
    /// letter suffix (`<stem>-a`, `<stem>-b`, …) and a pinned `"<stem> · A"`-style
    /// title so the group reads as one family in the sidebar. Worktree isolation is
    /// mandatory here — the same checkout can't back N concurrent agents — so callers
    /// only reach this when the worktree toggle is on. Keeps every session that
    /// starts and surfaces a single aggregate error for any that don't; selects the
    /// first success. Returns the sessions that started (possibly fewer than `count`).
    @discardableResult
    func createFanOut(provider: ProviderId, cwd: String, skipPermissions: Bool,
                      count: Int, initialInput: String?) async -> [Session] {
        let letters = FanOut.letters(count: count)
        let branchStem = String(UUID().uuidString.prefix(6)).lowercased()
        let titleStem = FanOut.titleStem(for: initialInput ?? "")
        var created: [Session] = []
        for (i, letter) in letters.enumerated() {
            let s = await create(
                provider: provider, cwd: cwd, skipPermissions: skipPermissions,
                isolateWorktree: true, initialInput: initialInput, select: i == 0,
                worktreeName: FanOut.worktreeName(stem: branchStem, letter: letter))
            if let s {
                s.setTitle(FanOut.groupTitle(stem: titleStem, letter: letter))
                created.append(s)
            }
        }
        let failures = letters.count - created.count
        if failures > 0 {
            errorMessage = created.isEmpty
                ? "Fan-out failed: couldn't start any of \(letters.count) sessions."
                : "Fan-out: started \(created.count) of \(letters.count) sessions; \(failures) failed."
        }
        refresh()
        return created
    }

    /// Start a new session directly in a given folder + provider, bypassing the
    /// NewSessionView sheet. Mirrors the web sidebar's per-folder "+" agent menu
    /// (accept-all off, no worktree). Both callers — the folder "+" popover and ⌘N
    /// (`quickNewSession`) — are explicit "give me a new session" gestures, so we
    /// select it and move the grid + terminal focus to it once it's up.
    func createInFolder(provider: ProviderId, cwd: String) {
        Task { await create(provider: provider, cwd: cwd, skipPermissions: true, isolateWorktree: false, select: true) }
    }

    /// ⌘N: open a new session mirroring the current selection's agent + working
    /// directory, so the common "another window on the same project" case is one
    /// keystroke. Falls back to the New Session sheet when nothing is selected (no
    /// context to clone from).
    func quickNewSession() {
        guard let sel = selection,
              let meta = (sessions + externalSessions).first(where: { $0.id == sel }) else {
            showingNewSession = true
            return
        }
        createInFolder(provider: meta.provider, cwd: meta.cwd)
    }

    /// Open the user's editor (`JUANCODE_EDITOR`, default nvim) as a session rooted
    /// in `sessionId`'s effective working directory — its worktree when isolated,
    /// else its cwd — so the editor lands in the same checkout the agent edits.
    /// `file`, when given and inside that directory, opens directly. Spawns off the
    /// main actor (forkpty + login-shell binary resolution) like `create`, then
    /// selects the new pane. No-op if the source session is unknown or is itself an
    /// editor.
    func openEditorSession(_ sessionId: String, file: String? = nil) {
        guard let parent = appState.registry.get(sessionId)?.meta
                ?? sessions.first(where: { $0.id == sessionId }),
              parent.kind != .editor else { return }
        let grid = TerminalGrid.spawn
        let state = appState
        Task {
            do {
                let s = try await Task.detached(priority: .userInitiated) {
                    try state.registry.createEditor(parent: parent, file: file, cols: grid.cols, rows: grid.rows)
                }.value
                refresh()
                selection = s.id
                focusTerminal()
            } catch {
                errorMessage = "Couldn't open the editor: \(error)"
            }
        }
    }

    /// Open an editor session for the current selection (toolbar / shortcut). No-op
    /// when nothing suitable is selected.
    func openEditorForSelection() {
        guard let sel = selection else { return }
        openEditorSession(sel)
    }

    // MARK: - External (terminal) sessions

    /// claude/codex conversations found on disk that juancode didn't create —
    /// surfaced in the sidebar behind the "Show terminal sessions" toggle as
    /// synthesized exited metas (id == CLI session id) you can resume by selecting.
    var externalSessions: [SessionMeta] = []
    /// Whether more terminal sessions exist beyond the loaded window (drives "Load more").
    var externalHasMore = false
    /// Ids in `externalSessions`, for O(1) "is this row external?" checks.
    @ObservationIgnored private var externalIds: Set<String> = []
    @ObservationIgnored private var externalLoading = false
    /// How many terminal sessions are currently loaded; grows by `externalPageSize`
    /// on "Load more" so we never read every transcript at once.
    @ObservationIgnored private var externalLimit = 0
    private let externalPageSize = 25

    /// True if `id` is a not-yet-imported terminal session (vs. one of ours).
    func isExternal(_ id: String) -> Bool { externalIds.contains(id) }

    // MARK: - "Continue existing" picker (new-session flow, juancode-g4c)

    /// Resumable CLI conversations for the cwd currently shown in the new-session
    /// sheet, newest first — the per-workdir "Continue existing" list. Reloaded
    /// whenever that cwd changes; empty when none are available.
    private(set) var resumableSessions: [ResumableSession] = []
    /// Whether a `loadResumableSessions` scan is in flight (drives a spinner).
    private(set) var resumableLoading = false
    /// The cwd the latest load was issued for, so a slower in-flight scan can drop
    /// its result once the user has moved on to a different folder.
    @ObservationIgnored private var resumableCwd: String?

    /// Load the resumable external CLI conversations for `cwd` to back the
    /// new-session "Continue existing" picker (juancode-g4c). Uses the cheap,
    /// cwd-scoped header lookup (`listExternalSessions`), drops any conversation
    /// juancode already owns (`usedCliSessionIds`), then derives a display title per
    /// hit. Debounced so typing a path doesn't scan on every keystroke, and stale
    /// results (cwd changed mid-load) are discarded.
    func loadResumableSessions(for cwd: String) {
        let target = cwd.trimmingCharacters(in: .whitespaces)
        resumableCwd = target
        guard !target.isEmpty else {
            resumableSessions = []
            resumableLoading = false
            return
        }
        resumableLoading = true
        resumableSessions = []
        Task {
            // Debounce keystrokes in the directory field before touching disk.
            try? await Task.sleep(for: .milliseconds(300))
            guard resumableCwd == target else { return }
            let used = appState.store.usedCliSessionIds()
            let rows = await Task.detached(priority: .utility) { () -> [ResumableSession] in
                let hits = listExternalSessions(cwd: target)
                    .filter { !used.contains($0.cliSessionId) }
                var out: [ResumableSession] = []
                for hit in hits {
                    let title = await deriveSessionTitle(hit.provider, hit.cliSessionId)
                    out.append(ResumableSession(
                        provider: hit.provider, cliSessionId: hit.cliSessionId,
                        startMs: hit.startMs,
                        title: title ?? (target as NSString).lastPathComponent))
                }
                return out
            }.value
            guard resumableCwd == target else { return }  // a newer load superseded us
            resumableSessions = rows
            resumableLoading = false
        }
    }

    /// Adopt + resume the chosen "Continue existing" conversation via the T2 path
    /// (`adoptExternal`), then drop it from the picker list. Returns the new
    /// session's id, or nil if juancode already owned this conversation.
    @discardableResult
    func adoptResumable(_ session: ResumableSession, cwd: String) -> String? {
        let meta = adoptExternal(provider: session.provider, cliSessionId: session.cliSessionId,
                                 cwd: cwd.trimmingCharacters(in: .whitespaces), startMs: session.startMs)
        if meta != nil { resumableSessions.removeAll { $0.id == session.id } }
        return meta?.id
    }

    /// (Re)load the most recent terminal sessions, deduped against the sessions
    /// juancode already owns. Starts at one page; resets the window each call.
    func loadExternalSessions() {
        externalLimit = externalPageSize
        fetchExternal()
    }

    /// Grow the window by one page (the "Load more" action).
    func loadMoreExternalSessions() {
        externalLimit += externalPageSize
        fetchExternal()
    }

    private func fetchExternal() {
        guard !externalLoading else { return }
        externalLoading = true
        let used = appState.store.usedCliSessionIds()
        let limit = externalLimit
        Task {
            let result = await Task.detached(priority: .utility) {
                await discoverExternalSessions(limit: limit, excluding: used)
            }.value
            externalSessions = result.sessions.map { ext in
                SessionMeta(id: ext.id, provider: ext.provider, cwd: ext.cwd, title: ext.title,
                            status: .exited, exitCode: nil, createdAt: ext.lastActiveMs,
                            updatedAt: ext.lastActiveMs, cliSessionId: ext.id,
                            skipPermissions: true, worktreePath: nil, usage: nil)
            }
            externalIds = Set(externalSessions.map(\.id))
            externalHasMore = result.hasMore
            externalLoading = false
        }
    }

    /// Import a discovered terminal session: register it as a real juancode session
    /// (fresh internal id, same CLI conversation) and resume its CLI conversation.
    func importExternalSession(_ id: String) {
        guard let ext = externalSessions.first(where: { $0.id == id }) else { return }
        var meta = ext
        meta.id = UUID().uuidString // our own key; `cliSessionId` still points at the conversation
        appState.store.insert(meta)
        externalSessions.removeAll { $0.id == id }
        externalIds.remove(id)
        refresh()
        selection = meta.id
        Task {
            do {
                let grid = TerminalGrid.spawn
                _ = try appState.registry.resume(meta, cols: grid.cols, rows: grid.rows)
                refresh()
            } catch {
                errorMessage = "Couldn't resume terminal session: \(error)"
            }
        }
    }

    /// Adopt an external CLI conversation identified directly by
    /// `(provider, cliSessionId, cwd, startMs)` — the in-process twin of the
    /// server's `.adoptExternal` wire path, and the lower-level entry behind
    /// `listExternalSessions`-driven UI (juancode-iqi). Persists a juancode row
    /// pointing at the conversation and resumes it live with no prior scrollback
    /// (the CLI reprints its own context). No-op when we already own this
    /// `cliSessionId`. Title + usage derive once the resumed session polls its
    /// transcript. Returns the new meta (nil if skipped).
    @discardableResult
    func adoptExternal(provider: ProviderId, cliSessionId: String, cwd: String, startMs: Int,
                       select: Bool = true) -> SessionMeta? {
        guard !appState.store.usedCliSessionIds().contains(cliSessionId) else { return nil }
        let meta = SessionMeta.adopting(provider: provider, cliSessionId: cliSessionId,
                                        cwd: cwd, startMs: startMs)
        appState.store.insert(meta)
        refresh()
        if select { selection = meta.id }
        Task {
            do {
                let grid = TerminalGrid.spawn
                _ = try appState.registry.resume(meta, cols: grid.cols, rows: grid.rows)
                refresh()
            } catch {
                errorMessage = "Couldn't resume terminal session: \(error)"
            }
        }
        return meta
    }

    // MARK: - Open pull requests (per-folder PR popover)

    /// The cached PR list for `cwd`, if loaded yet.
    func prs(_ cwd: String) -> PrListResult? { prsByCwd[cwd] }

    /// Load (or refresh) the open PRs for `cwd` via the real `gh` CLI. Runs off the
    /// main actor since it shells out, then publishes the result. Coalesces
    /// concurrent calls for the same cwd. Failures land as `available: false`
    /// inside `getOpenPrs`, so the popover trigger just stays hidden.
    func loadPrs(_ cwd: String) {
        guard !prsLoading.contains(cwd) else { return }
        prsLoading.insert(cwd)
        Task {
            let result = await Task.detached(priority: .utility) { await getOpenPrs(cwd) }.value
            prsByCwd[cwd] = result
            prsLoading.remove(cwd)
        }
    }

    /// Debounced, repo-scoped `gh pr list --search` backing the PR popover's
    /// Mine/Assigned/text filters. The popover filters the cached set instantly for
    /// responsiveness; this runs in the background and unions in matches that fall
    /// beyond the newest-`MAX_PRS` firehose the initial `loadPrs` caps at (e.g. your
    /// own older PRs, or an old PR matched by the query). Nothing to scope (no
    /// query, no Mine/Assigned) → no-op, since the base list already covers that
    /// view. Coalesces rapid keystrokes/toggles via a per-cwd cancellable task.
    func backfillPrs(_ cwd: String, mine: Bool, assigned: Bool, query: String) {
        prsBackfillTasks[cwd]?.cancel()
        guard let qualifiers = prBackfillQuery(
            mine: mine, assigned: assigned, query: query,
            viewer: prsByCwd[cwd]?.viewer ?? "") else { return }
        prsBackfillTasks[cwd] = Task { [qualifiers] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .utility) {
                await searchOpenPrs(cwd, search: qualifiers)
            }.value
            if Task.isCancelled || found.isEmpty { return }
            guard var existing = prsByCwd[cwd], existing.available else { return }
            existing.prs = mergePrLists(existing.prs, found)
            prsByCwd[cwd] = existing
        }
    }

    /// Spawn a Claude session in the PR's folder seeded with a prompt that asks the
    /// agent to review the PR and its diff — mirrors the web "Work on" action.
    /// Always uses the folder's cwd (not a worktree) so the branch context lines up.
    func workOnPr(_ pr: PullRequest, cwd: String) {
        Task {
            await create(provider: .claude, cwd: cwd, skipPermissions: true,
                         isolateWorktree: false, initialInput: prPrompt(pr))
        }
    }

    // MARK: - GitHub view (juancode-2t6)

    /// The project folders the GitHub view lists: the trackable project roots of
    /// the current sessions unioned with every folder a PR list was already
    /// loaded for, so a folder doesn't vanish from the view once its sessions
    /// close.
    var githubFolders: [String] {
        Array(Set(trackableFolders).union(prsByCwd.keys)).sorted()
    }

    /// Total open PRs across every loaded folder — the sidebar GitHub row badge.
    var openPrTotal: Int {
        prsByCwd.values.filter(\.available).reduce(0) { $0 + $1.prs.count }
    }

    /// Whether any tracked PR has an unresolved decision — the sidebar row's
    /// orange dot.
    var trackedPrNeedsAttention: Bool {
        tracked.values.contains { !$0.notifications.isEmpty }
    }

    /// Open the GitHub view and kick a PR refresh across every folder.
    func openGitHub() {
        showingGitHub = true
        github.refresh(model: self)
    }

    func toggleGitHubView() {
        if showingGitHub { showingGitHub = false } else { openGitHub() }
    }

    /// "Open diff" from the GitHub view: land on the best session for the PR with
    /// its Changes panel showing the PR diff — the tracked PR's live session,
    /// else the folder's focused/most-recent live session, else spawn a fresh
    /// work-on session (decision D: no new diff renderer). Setting `selection`
    /// dismisses the view via its didSet.
    func openPrDiff(_ pr: PullRequest, cwd: String) {
        let target = trackedPr(cwd: cwd, number: pr.number).flatMap { liveSession($0.sessionId) }
            ?? focusedLiveSession(in: cwd)
        guard let target else {
            workOnPr(pr, cwd: cwd)
            return
        }
        selection = target.id
        setChangesSource(target.id, .pr(pr))
        // Reveal the Changes panel (same UserDefaults contract as `openChanges`,
        // which would reset the source to the working tree).
        let d = UserDefaults.standard
        d.set("Changes", forKey: "session.sidePanel.tab")
        d.set(true, forKey: "session.sidePanel.shown")
        requestChangesFocus(target.id)
    }

    // MARK: - Full-text transcript search (juancode-wx9)

    /// The current search query (bound to the SearchPanel text field).
    var searchQuery = ""
    /// Hits for the most recently completed search, in rank order.
    var searchResults: [SearchHit] = []
    /// True while a search is in flight (for a "Searching…" affordance).
    var searching = false
    /// Monotonic token so a slow earlier search can't clobber a newer one.
    private var searchToken = 0

    /// Run full-text search over persisted session titles + scrollback for `query`,
    /// mirroring the web `/api/search` path: queries under 2 chars clear results;
    /// otherwise we hit the in-process FTS store off the main actor (it shells into
    /// SQLite) and publish the ranked hits. Stale responses are dropped via a token.
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            searching = false
            searchResults = []
            return
        }
        searchToken += 1
        let token = searchToken
        searching = true
        let store = appState.store
        Task {
            let hits = await Task.detached(priority: .userInitiated) {
                store.search(q, limit: 50)
            }.value
            guard token == self.searchToken else { return }
            self.searchResults = hits
            self.searching = false
        }
    }

    /// Open the session a search hit points at and dismiss the search affordance.
    func openSearchHit(_ hit: SearchHit) {
        selection = hit.meta.id
    }

    // MARK: - Beads issues (per-folder issue picker — juancode-sfh)

    /// bd issue listings per folder cwd, loaded lazily by `FolderHeader` and
    /// refreshed in the background. Mirrors `prsByCwd`. `available: false` (no
    /// tracker / bd missing) keeps the popover trigger hidden.
    var beadsByCwd: [String: BeadsResult] = [:]
    /// cwds with an issue fetch in flight, so a refresh doesn't stampede.
    private var beadsLoading: Set<String> = []

    /// The cached issue listing for `cwd`, if loaded yet.
    func beads(_ cwd: String) -> BeadsResult? { beadsByCwd[cwd] }

    /// Load (or refresh) the bd issues for `cwd` via the real `bd` CLI. Runs off
    /// the main actor since it shells out, then publishes the result. Coalesces
    /// concurrent calls for the same cwd. Mirrors `loadPrs`.
    func loadBeads(_ cwd: String) {
        guard !beadsLoading.contains(cwd) else { return }
        beadsLoading.insert(cwd)
        Task {
            let result = await Task.detached(priority: .utility) { await getBeads(cwd) }.value
            beadsByCwd[cwd] = result
            beadsLoading.remove(cwd)
        }
    }

    // MARK: - Per-folder / per-worktree branch (sidebar labels)

    /// Working-tree git state keyed by folder cwd, backing the sidebar's project
    /// branch label (main checkout) and the worktree-session row branch. Distinct
    /// from `gitStateBySession` (keyed by session id, loaded by the ChangesPanel):
    /// this one is cheap, folder-scoped, and refreshed on header/row appear.
    var gitStateByCwd: [String: GitState] = [:]
    /// cwds with a folder git-state fetch in flight, so appears don't stampede.
    private var gitStateCwdLoading: Set<String> = []

    /// The cached branch/state for `cwd`, if loaded yet.
    func folderGitState(_ cwd: String) -> GitState? { gitStateByCwd[cwd] }

    /// Load (or refresh) the git state for `cwd` via `getGitState` (a light
    /// `symbolic-ref` shell-out). Runs off the main actor; coalesces concurrent
    /// calls. Non-git folders resolve to `git: false` (branch nil), so the label
    /// just stays hidden. Mirrors `loadPrs`/`loadBeads`.
    func loadFolderGitState(_ cwd: String) {
        guard !gitStateCwdLoading.contains(cwd) else { return }
        gitStateCwdLoading.insert(cwd)
        Task {
            let state = await Task.detached(priority: .utility) { await getGitState(cwd) }.value
            gitStateByCwd[cwd] = state
            gitStateCwdLoading.remove(cwd)
        }
    }

    /// "Work on" a bd issue: compose `Work on <id>: <title>\n\n<description>` and
    /// inject it into the focused/live session as if typed. The issue's status is
    /// left untouched (side-effect-free, per juancode-sfh).
    ///
    /// If the folder has a live focused session it lands there; otherwise we fall
    /// back to the folder's most-recent live session, and if none exists we spawn a
    /// fresh Claude session seeded with the prompt (mirrors `workOnPr`). The bd
    /// `show` lookup (for the full description) runs off the main actor.
    func workOnIssue(_ issue: BeadsIssue, cwd: String) {
        Task {
            let id = issue.id
            let description = await Task.detached(priority: .utility) {
                await getBeadsDescription(cwd, id: id)
            }.value
            let prompt = issuePrompt(id: id, title: issue.title, description: description)
            if let session = focusedLiveSession(in: cwd) {
                // Submit it as if typed: idle → runs now, busy → queued by the CLI.
                // Bracketed paste + separate Enter so the multi-line prompt isn't
                // misread as a literal paste and left sitting unsent in the input.
                session.submit(prompt)
            } else {
                // No live session for this folder — start one seeded with the prompt.
                await create(provider: .claude, cwd: cwd, skipPermissions: true,
                             isolateWorktree: false, initialInput: prompt)
            }
        }
    }

    /// The live session to inject an issue into for `cwd`: the current selection if
    /// it's live and rooted in `cwd`, else the most recently-created live session
    /// in that folder. `nil` when the folder has no live session.
    private func focusedLiveSession(in cwd: String) -> Session? {
        if let sel = selection, let s = liveSession(sel), s.meta.cwd == cwd { return s }
        return appState.registry.all()
            .filter { $0.meta.cwd == cwd }
            .max { $0.meta.createdAt < $1.meta.createdAt }
    }

    // MARK: - Tracked PRs (juancode-it5)

    /// PRs under continuous watch, keyed by `TrackedPr.key(cwd:number:)`. A
    /// read-only mirror of `PrTrackingEngine` — the single owner of the watch
    /// list, poll loop, and persistence (juancode-b4m) — kept fresh via
    /// `subscribeTrackedMirror()` so badges/panels observe it like local state.
    private(set) var tracked: [String: TrackedPr] = [:]
    /// Linear issues under continuous watch, keyed by `TrackedIssue.key(cwd:identifier:)`
    /// (juancode-z4v). The same poll loop diffs each one's Linear activity and feeds
    /// next-step prompts into its agent session — the Linear twin of `tracked`.
    var trackedIssues: [String: TrackedIssue] = [:]
    /// How often the poll loop revisits every tracked Linear issue.
    private let trackPollInterval: Duration = .seconds(120)
    private var trackLoop: Task<Void, Never>?

    /// While tracking is live, hold an idle-system-sleep assertion so the poll loop
    /// keeps fetching PR/issue activity and driving fixes in the background even when
    /// the Mac would otherwise idle-sleep. `.idleSystemSleepDisabled` lets the display
    /// sleep (the screen can turn off) while keeping the system awake — the caffeinated
    /// tracker the user asked for. Acquired with the loop, released when nothing is
    /// tracked, so it never pins the machine awake longer than needed. Independent of
    /// the user's manual Keep Awake toggle (`keepAwakeToken`), which serves a different
    /// purpose and may be off.
    @ObservationIgnored private var trackKeepAwakeToken: NSObjectProtocol?

    /// Look up a tracked PR by folder + number (for the "Track / Tracking" toggle).
    func trackedPr(cwd: String, number: Int) -> TrackedPr? {
        tracked[TrackedPr.key(cwd: cwd, number: number)]
    }

    /// The tracked PR whose agent session is `id`, if any — drives the PR label on a
    /// session row (juancode-kxy).
    func trackedPr(forSession id: String) -> TrackedPr? {
        tracked.values.first { $0.sessionId == id }
    }

    /// All tracked PRs, most recently polled first, for the global panel (juancode-38z).
    var trackedList: [TrackedPr] {
        tracked.values.sorted {
            ($0.lastPolledAt ?? 0, $0.number) > ($1.lastPolledAt ?? 0, $1.number)
        }
    }

    /// The tracked Linear issue whose agent session is `id`, if any.
    func trackedIssue(forSession id: String) -> TrackedIssue? {
        trackedIssues.values.first { $0.sessionId == id }
    }

    /// All tracked issues, most recently polled first, for the global panel.
    var trackedIssuesList: [TrackedIssue] {
        trackedIssues.values.sorted {
            ($0.lastPolledAt ?? 0) != ($1.lastPolledAt ?? 0)
                ? ($0.lastPolledAt ?? 0) > ($1.lastPolledAt ?? 0)
                : $0.identifier > $1.identifier
        }
    }

    /// Start tracking a PR — forwarded to `PrTrackingEngine`, the single owner
    /// (juancode-b4m). The engine spawns the dedicated seeded agent session and
    /// runs the poll loop; the GUI just selects the spawned session so "Track" is
    /// still an explicit "take me there". The mirror updates via the subscription.
    func trackPr(_ pr: PullRequest, cwd: String) {
        Task {
            guard let entry = await appState.prTracking.track(pr, cwd: cwd) else { return }
            selection = entry.sessionId
            focusTerminal()
        }
    }

    /// Stop tracking a PR (forwarded to the engine). Leaves its agent session
    /// alone (the user may still want it); just drops it from the watch list.
    func untrackPr(_ id: String) {
        Task { await appState.prTracking.untrack(id) }
    }

    /// Queue a prompt into a session's message queue and kick it — the same
    /// idle-edge delivery `submitReview` uses, so a "Send to agent" never
    /// interrupts the agent mid-turn. Safe when the session isn't live: the
    /// queue holds the message and the next revival flushes it.
    func queuePrompt(sessionId: String, text: String) {
        appState.messageQueue.add(sessionId, text: text)
        liveSession(sessionId)?.kickQueue()
    }

    /// "Track & send" from the GitHub view: start tracking the PR (the engine
    /// spawns + seeds the agent session and returns the entry synchronously),
    /// then queue the prompt on that session. Unlike `trackPr` this does NOT
    /// jump to the spawned session — the user is reading the PR conversation
    /// and just handed one comment off. Returns false when tracking failed
    /// (spawn failure) and nothing was queued.
    func trackPrAndQueue(_ pr: PullRequest, cwd: String, prompt: String) async -> Bool {
        if let entry = await appState.prTracking.track(pr, cwd: cwd) {
            queuePrompt(sessionId: entry.sessionId, text: prompt)
            return true
        }
        // `track` returns nil when already tracked (e.g. raced with another
        // surface) — fall back to the mirror's session.
        if let t = trackedPr(cwd: cwd, number: pr.number) {
            queuePrompt(sessionId: t.sessionId, text: prompt)
            return true
        }
        return false
    }

    /// Mirror the engine-owned tracked-PR watch list into `tracked`. The engine
    /// hands the current snapshot synchronously on subscribe, so the mirror also
    /// seeds itself at launch (including a restored watch list). Needs-decision
    /// escalations ride the same subscription and surface as OS notifications.
    private func subscribeTrackedMirror() {
        let engine = appState.prTracking
        Task {
            _ = await engine.subscribe { [weak self] change in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch change {
                    case .tracked(let list):
                        self.applyTrackedMirror(list)
                    case let .notification(trackedId, prNumber, notification):
                        self.notifyTrackedPrDecision(
                            trackedId: trackedId, prNumber: prNumber, notification: notification)
                    }
                }
            }
        }
    }

    /// Surface an engine needs-decision escalation as an OS notification keyed by
    /// the PR's agent session, so the existing click-through (`AgentNotifier` →
    /// `revealSession`) lands on the session — and `selection`'s didSet dismisses
    /// the GitHub view on the way.
    private func notifyTrackedPrDecision(trackedId: String, prNumber: Int,
                                         notification: TrackNotification) {
        // The mirror still holds the entry at notification time (the engine
        // broadcasts `.tracked` after per-poll notifications).
        guard let entry = tracked[trackedId] else { return }
        agentNotifier.post(
            sessionId: entry.sessionId,
            title: "PR #\(prNumber) needs a decision",
            subtitle: (entry.cwd as NSString).lastPathComponent,
            body: notification.message,
            critical: true)
    }

    private func applyTrackedMirror(_ list: [TrackedPr]) {
        tracked = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        updateTrackKeepAwake()
    }

    /// Stop the Linear-issues poll loop once no issue is being watched. (The PR
    /// loop lives in `PrTrackingEngine`; only the keep-awake assertion is shared.)
    private func stopTrackLoopIfIdle() {
        if trackedIssues.isEmpty {
            trackLoop?.cancel(); trackLoop = nil
        }
        updateTrackKeepAwake()
    }

    /// Hold the background-tracking keep-awake assertion while anything — a
    /// mirrored tracked PR (engine-owned poll) or a tracked Linear issue (local
    /// loop) — is under watch; release it when both are empty.
    private func updateTrackKeepAwake() {
        if tracked.isEmpty && trackedIssues.isEmpty {
            releaseTrackKeepAwake()
        } else {
            acquireTrackKeepAwake()
        }
    }

    /// Acquire the background-tracking idle-sleep assertion. Idempotent.
    private func acquireTrackKeepAwake() {
        guard trackKeepAwakeToken == nil else { return }
        trackKeepAwakeToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Tracking PRs/issues in the background")
    }

    /// Release the background-tracking idle-sleep assertion. Idempotent.
    private func releaseTrackKeepAwake() {
        if let token = trackKeepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            trackKeepAwakeToken = nil
        }
    }

    /// Dismiss a surfaced decision once the user has dealt with it (forwarded to
    /// the engine; the mirror updates via the subscription).
    func resolveNotification(prId: String, notificationId: String) {
        Task { await appState.prTracking.resolveNotification(trackedId: prId, notificationId: notificationId) }
    }

    /// Start tracking a Linear issue: fetch it (for title/url + an initial baseline so
    /// existing comments/state aren't replayed), spawn a dedicated Claude session seeded
    /// with the issue context + do-or-escalate contract, register it, and ensure the
    /// poll loop is running. No-op if already tracked. The Linear twin of `trackPr`.
    func trackIssue(identifier: String, cwd: String) {
        let key = TrackedIssue.key(cwd: cwd, identifier: identifier)
        guard trackedIssues[key] == nil else { return }
        Task {
            guard let activity = await Task.detached(priority: .utility, operation: {
                await getIssueActivity(identifier)
            }).value else {
                errorMessage = linearToken() == nil
                    ? "Set LINEAR_API_KEY (or JUANCODE_LINEAR_TOKEN) in your environment to track Linear issues."
                    : "Couldn't fetch Linear issue \(identifier)."
                return
            }
            let seed = trackIssueSeedPrompt(identifier: activity.identifier,
                                            title: activity.title, url: activity.url)
            guard let session = await create(provider: .claude, cwd: cwd, skipPermissions: true,
                                             isolateWorktree: false, initialInput: seed,
                                             model: "opus") else { return }
            // Baseline from the activity we already fetched, so the first poll doesn't
            // fire events for comments/state that predate tracking.
            let baseline = classifyIssueActivity(prev: IssueTrackSnapshot(), activity: activity).snapshot
            trackedIssues[key] = TrackedIssue(
                identifier: activity.identifier, title: activity.title, url: activity.url,
                cwd: cwd, sessionId: session.id, snapshot: baseline,
                lastPolledAt: nowMs(), lastStateName: activity.stateName)
            persistTrackedIssues()
            startTrackLoop()
        }
    }

    /// Stop tracking an issue. Leaves its agent session alone; just drops it from the
    /// watch list. Stops the loop when nothing (PR or issue) remains.
    func untrackIssue(_ id: String) {
        trackedIssues[id] = nil
        persistTrackedIssues()
        stopTrackLoopIfIdle()
    }

    /// Dismiss a surfaced issue decision once the user has dealt with it.
    func resolveIssueNotification(issueId: String, notificationId: String) {
        trackedIssues[issueId]?.notifications.removeAll { $0.id == notificationId }
        persistTrackedIssues()
    }

    /// The viewer's assigned Linear issues, for the "pick from assigned issues" picker
    /// when starting tracking (juancode-7sa). Loaded lazily on demand.
    var assignedIssues: [IssueSummary] = []
    var assignedIssuesLoading = false

    /// Load the viewer's assigned issues into `assignedIssues` for the tracking picker.
    /// Surfaces the same missing-token hint as `trackIssue` when no key is set.
    func loadAssignedIssues() {
        guard linearToken() != nil else {
            errorMessage = "Set LINEAR_API_KEY (or JUANCODE_LINEAR_TOKEN) in your environment to track Linear issues."
            return
        }
        assignedIssuesLoading = true
        Task {
            let issues = await Task.detached(priority: .utility, operation: {
                await getAssignedIssues()
            }).value
            assignedIssues = issues
            assignedIssuesLoading = false
        }
    }

    /// Distinct project roots among the current in-workspace sessions, sorted — the
    /// folder choices when starting to track a Linear issue (the agent runs there).
    var trackableFolders: [String] {
        let cwds = (sessions + externalSessions)
            .map { worktreeRepoRoots[$0.cwd] ?? projectCwd(for: $0.cwd) }
            .filter { Config.isUnderWorkspaceRoot($0) && $0 != OraclePaths.controlDir }
        return Array(Set(cwds)).sorted()
    }

    // Tracked issues survive an app restart via UserDefaults — the watch list +
    // diff baseline are restored, so the loop doesn't replay history. The driving
    // session may be exited after a restart; prompts resume injecting once it's
    // reactivated, while the badge/state keep working in the meantime. (Tracked
    // PRs moved to SQLite, owned by `PrTrackingEngine` — juancode-b4m.)
    private static let trackedIssuesDefaultsKey = "juancode.trackedIssues.v1"

    private func persistTrackedIssues() {
        let list = Array(trackedIssues.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.trackedIssuesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.trackedIssuesDefaultsKey)
        }
    }

    private func restoreTrackedIssues() {
        if let data = UserDefaults.standard.data(forKey: Self.trackedIssuesDefaultsKey),
           let list = try? JSONDecoder().decode([TrackedIssue].self, from: data) {
            for issue in list { trackedIssues[issue.id] = issue }
        }
        if !trackedIssues.isEmpty { startTrackLoop() }
    }

    private func startTrackLoop() {
        guard trackLoop == nil else { return }
        acquireTrackKeepAwake()
        trackLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollTrackedIssuesOnce()
                try? await Task.sleep(for: self?.trackPollInterval ?? .seconds(20))
            }
        }
    }

    /// One pass over every tracked Linear issue: fetch its activity off the main actor,
    /// classify what changed, inject next-step prompts into the agent session, and raise
    /// notifications for changes that need a human decision. The Linear twin of
    /// `PrTrackingEngine.pollOnce`.
    func pollTrackedIssuesOnce() async {
        for (key, issue) in trackedIssues {
            let identifier = issue.identifier
            guard let activity = await Task.detached(priority: .utility, operation: {
                await getIssueActivity(identifier)
            }).value else { continue }

            // The entry may have been untracked while we were off-actor.
            guard var entry = trackedIssues[key] else { continue }
            let result = classifyIssueActivity(prev: entry.snapshot, activity: activity)
            entry.snapshot = result.snapshot
            entry.lastPolledAt = nowMs()
            entry.lastStateName = activity.stateName
            entry.title = activity.title  // keep the cached title fresh

            var reasons: [String] = []
            for event in result.events {
                switch event {
                case .autoFix(let reason):
                    reasons.append(reason)
                case .needsDecision(let reason):
                    entry.notifications.append(IssueTrackNotification(
                        id: UUID().uuidString, issueIdentifier: identifier,
                        message: reason, createdAt: nowMs()))
                case .closed:
                    break  // issue classifier never emits this; PR-only terminal event
                }
            }
            if !reasons.isEmpty, let session = liveSession(entry.sessionId) {
                let prompt = issueActivityPrompt(identifier: identifier, reasons: reasons)
                // Bracketed paste + separate Enter (via `submit`), not a raw
                // `"\(prompt)\r"` burst — the CLI reads that burst as a paste and
                // keeps the CR literal, so the prompt lands but never submits.
                session.submit(prompt)
            }
            trackedIssues[key] = entry
        }
        persistTrackedIssues()
    }

    /// Revive an exited session (mirrors the WS `reactivate` path). Returns whether
    /// the prior CLI conversation actually resumed; `false` means it couldn't (no
    /// id, spawn failed, or the resume died fast — see `confirmResumeSucceeded`), so
    /// callers like the Oracle dock can fall back to a fresh spawn. `grid` overrides
    /// the spawn size — the Oracle dock passes its own narrow grid so the resumed CLI
    /// boots at the dock's width instead of the wide main-window `TerminalGrid.spawn`,
    /// which otherwise wraps the TUI into garbage inside the drawer.
    @discardableResult
    func reactivate(_ id: String, grid: (cols: Int, rows: Int)? = nil) async -> Bool {
        if isLive(id) { return true }
        // The db row can be gone if the retention cap pruned it after this pane was
        // opened; fall back to the run-lifetime meta cache and re-insert so opening
        // an old session revives it instead of failing with "not found" (juancode).
        guard var meta = appState.store.get(id) ?? metaCache[id] else { return false }
        if appState.store.get(id) == nil { appState.store.insert(meta) }
        if meta.cliSessionId == nil {
            if let recovered = await recoverCliSessionId(
                meta.provider, cwd: meta.cwd, createdAtMs: meta.createdAt,
                excludeIds: appState.store.usedCliSessionIds()) {
                appState.store.setCliSessionId(id, cliSessionId: recovered)
                meta.cliSessionId = recovered
            }
        }
        guard meta.cliSessionId != nil else {
            errorMessage = "No prior CLI conversation could be found to resume this session."
            appState.activityLog.log("reviveFailed", sessionId: id, project: meta.cwd,
                                     fields: ["reason": "unresumable"])
            return false
        }
        // A pinned-id session that booted but never got a turn has no transcript to
        // resume — `--resume` would just fast-exit and churn scrollback. Detect that
        // up front (shared with the WS revive path) and report unresumable so
        // callers boot a fresh session in place instead.
        if resumeNeedsFreshStart(meta) { return false }
        do {
            let prior = appState.store.getScrollback(id) ?? []
            let seed: [UInt8] = prior.isEmpty
                ? [] : prior + Array("\r\n\u{1B}[2m── session resumed ──\u{1B}[0m\r\n".utf8)
            let g = grid ?? TerminalGrid.spawn
            let session = try appState.registry.resume(meta, cols: g.cols, rows: g.rows, priorScrollback: seed)
            refresh()
            return await confirmResumeSucceeded(session, sessionId: id, priorScrollback: prior)
        } catch {
            errorMessage = "Failed to resume: \(error)"
            appState.activityLog.log("reviveFailed", sessionId: id, project: meta.cwd,
                                     fields: ["reason": "\(error)"])
            return false
        }
    }

    /// Verify a just-resumed pty actually attached to its prior conversation. A
    /// `<cli> --resume <staleId>` against a transcript the CLI no longer has exits
    /// almost immediately (`claude` prints "No conversation found with session ID:
    /// …" and quits); a genuine resume keeps the pty alive with its TUI up. So treat
    /// a fast exit as a failed resume and `invalidateFailedResume` — otherwise the
    /// banner + the CLI's "No conversation found" error get persisted into scrollback
    /// and re-seeded on every load, stacking "── session resumed ──" copies forever.
    private func confirmResumeSucceeded(_ session: Session, sessionId: String,
                                        priorScrollback: [UInt8]) async -> Bool {
        let graceMs = 5000, pollMs = 150
        var elapsed = 0
        while elapsed < graceMs {
            if !session.isRunning {
                invalidateFailedResume(sessionId, priorScrollback: priorScrollback)
                return false
            }
            try? await Task.sleep(for: .milliseconds(pollMs))
            elapsed += pollMs
        }
        return session.isRunning
    }

    /// Mark a session whose resume died fast as unresumable: drop the stale
    /// `cliSessionId` (so the next load spawns fresh instead of re-running the doomed
    /// `--resume`) and roll the persisted scrollback back to its pre-resume state
    /// (dropping the `── session resumed ──` banner + the CLI's failure output, so
    /// nothing stacks across reloads).
    private func invalidateFailedResume(_ sessionId: String, priorScrollback: [UInt8]) {
        guard var meta = appState.store.get(sessionId) else { return }
        appState.activityLog.log("resumeInvalidated", sessionId: sessionId, project: meta.cwd)
        meta.cliSessionId = nil
        meta.status = .exited
        appState.store.update(meta, scrollback: priorScrollback)
        refresh()
    }

    // MARK: - Session-restored banner (juancode-mya)

    /// The "restored from disk" banner phase for `id`, or nil when hidden.
    func restoredBannerPhase(_ id: String) -> SessionRestoredBanner.Phase? { restoredBanners[id] }

    /// Auto-revive a pane opened from the sidebar, announcing a "restored from disk"
    /// banner when this is the first revival of a session that was persisted (and not
    /// live) at launch. The banner distinguishes a booting resume (`.resuming`, which
    /// auto-dismisses on the first live byte or after a short grace) from a pane that
    /// couldn't be resumed (`.unresumable`, dismissible with its X). Non-restore opens
    /// (already live, or revived earlier this run) just fall through to `reactivate`.
    func openPersistedPane(_ id: String) async {
        guard !isLive(id) else { return }
        // Drive a per-row spinner while the (async, up to ~5s) resume is in flight, so
        // clicking an exited session gives immediate "working on it" feedback.
        activatingSessions.insert(id)
        defer { activatingSessions.remove(id) }
        let announce = launchRestoredIds.contains(id) && !revivedRestoresThisRun.contains(id)
        if announce {
            revivedRestoresThisRun.insert(id)
            applyRestoredBannerEvent(id, .restoreBegan)
        }
        let resumed = await reactivate(id)
        if resumed {
            if announce {
                watchFirstLiveOutput(id)
                scheduleRestoreGrace(id)
            }
            return
        }
        // Couldn't resume the prior conversation (most often: the session never
        // completed a turn, so Claude wrote no transcript). Rather than leave a dead
        // replay-only pane, boot a fresh live session in place — re-pinning the same
        // id means the first completed turn writes a transcript and future revives
        // resume cleanly. Clear the banner + any resume error first.
        if announce { applyRestoredBannerEvent(id, .dismissed) }
        errorMessage = nil
        await startFreshInPlace(id)
    }

    /// Boot a fresh CLI conversation for an exited session that couldn't be resumed,
    /// keeping its juancode id and pane (see `SessionRegistry.restartFresh`). No-op
    /// if it's already live or its meta is gone.
    private func startFreshInPlace(_ id: String) async {
        guard !isLive(id) else { return }
        guard let meta = appState.store.get(id) ?? metaCache[id] else { return }
        if appState.store.get(id) == nil { appState.store.insert(meta) }
        do {
            _ = try appState.registry.restartFresh(meta, cols: TerminalGrid.spawn.cols,
                                                   rows: TerminalGrid.spawn.rows)
            refresh()
        } catch {
            errorMessage = "Couldn't start a fresh session: \(error)"
        }
    }

    /// Dismiss the restored banner for `id` (the overlay's X — the only way to clear
    /// the replay-only `.unresumable` case).
    func dismissRestoredBanner(_ id: String) { applyRestoredBannerEvent(id, .dismissed) }

    /// Fold an event through the pure banner machine and reflect the result: a nil
    /// phase clears the entry and tears down any pending live-output watch.
    private func applyRestoredBannerEvent(_ id: String, _ event: SessionRestoredBanner.Event) {
        let next = SessionRestoredBanner.reduce(restoredBanners[id], on: event)
        if let next {
            restoredBanners[id] = next
        } else {
            restoredBanners.removeValue(forKey: id)
            cancelRestoreOutputWatch(id)
        }
    }

    /// Auto-dismiss the `.resuming` banner on the first LIVE (non-replay) pty byte —
    /// the moment the resumed CLI proves it's driving the pane, not just showing
    /// replayed history.
    private func watchFirstLiveOutput(_ id: String) {
        guard let session = liveSession(id) else { return }
        cancelRestoreOutputWatch(id)
        restoreOutputCancels[id] = session.subscribeOutput(replay: false) { [weak self] _ in
            Task { @MainActor in self?.applyRestoredBannerEvent(id, .liveOutput) }
        }
    }

    private func cancelRestoreOutputWatch(_ id: String) {
        restoreOutputCancels.removeValue(forKey: id)?()
    }

    /// Backstop the live-output dismiss: a resumed-but-idle agent may emit nothing, so
    /// fold the banner away after the grace window regardless.
    private func scheduleRestoreGrace(_ id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SessionRestoredBanner.resumeGraceSeconds))
            self?.applyRestoredBannerEvent(id, .graceElapsed)
        }
    }

    /// Rename a session. Trims the input; an empty name is ignored. Updates the
    /// live pty's meta when running (which persists + pins the title against the
    /// CLI-title poll), otherwise writes straight to the store.
    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let s = appState.registry.get(id) {
            s.setTitle(trimmed)
        } else {
            appState.store.setTitle(id, title: trimmed)
        }
        refresh()
    }

    /// Archive or unarchive a session. Persists the flag (via the live session
    /// when running) and clears the selection when hiding the selected one.
    func setArchived(_ id: String, _ archived: Bool) {
        if let s = appState.registry.get(id) {
            s.setArchived(archived)
        } else {
            appState.store.setArchived(id, archived: archived)
        }
        if archived, selection == id { selection = nil }
        refresh()
    }

    // MARK: - Recurring tasks (juancode-dgp)

    /// Recurring tasks, keyed by `RecurringTask.id`. A fixed-interval tick spawns a
    /// fresh agent session in each due task's folder with its prompt as initial input.
    var recurringTasks: [String: RecurringTask] = [:]
    /// How often the scheduler wakes to check for due tasks. Bounds fire precision —
    /// fine for the minutes-plus cadence recurring tasks are meant for.
    private let scheduleTickInterval: Duration = .seconds(30)
    private var scheduleLoop: Task<Void, Never>?

    /// All recurring tasks, soonest-to-fire first, for the future management UI.
    var recurringTasksList: [RecurringTask] {
        recurringTasks.values.sorted { $0.nextFireAt < $1.nextFireAt }
    }

    /// Register a recurring task and ensure the scheduler is running. Returns the
    /// created task. First run is one interval out (we don't fire on creation).
    @discardableResult
    func addRecurringTask(title: String, cwd: String, provider: ProviderId, prompt: String,
                          intervalSeconds: Int, skipPermissions: Bool = true) -> RecurringTask {
        let now = nowMs()
        let task = RecurringTask(
            title: title, cwd: cwd, provider: provider, prompt: prompt,
            intervalSeconds: intervalSeconds, skipPermissions: skipPermissions,
            createdAt: now, nextFireAt: initialFireTime(createdAt: now, intervalSeconds: intervalSeconds))
        recurringTasks[task.id] = task
        persistRecurringTasks()
        startScheduleLoop()
        return task
    }

    /// Stop and forget a recurring task. Stops the scheduler when none remain.
    func removeRecurringTask(_ id: String) {
        recurringTasks[id] = nil
        persistRecurringTasks()
        if recurringTasks.isEmpty { scheduleLoop?.cancel(); scheduleLoop = nil }
    }

    /// Pause or resume a recurring task without losing it.
    func setRecurringTaskEnabled(_ id: String, enabled: Bool) {
        guard var task = recurringTasks[id] else { return }
        task.enabled = enabled
        // Resuming a task that's overdue shouldn't fire a backlog — reschedule from now.
        if enabled, task.nextFireAt <= nowMs() {
            task.nextFireAt = nextRecurringFireTime(
                firedAt: nowMs(), intervalSeconds: task.intervalSeconds, now: nowMs())
        }
        recurringTasks[id] = task
        persistRecurringTasks()
        if enabled { startScheduleLoop() }
    }

    /// Fire a recurring task right now (the "Run now" action), then reschedule its
    /// next run one interval out from this moment — a manual run shouldn't double up
    /// with the slot that was already pending. Unlike the scheduler, this *selects*
    /// the spawned session: a Run-now is an explicit request to see the result.
    func runRecurringTaskNow(_ id: String) async {
        guard let task = recurringTasks[id] else { return }
        _ = await create(provider: task.provider, cwd: task.cwd,
                         skipPermissions: task.skipPermissions, isolateWorktree: false,
                         initialInput: task.prompt, select: true)
        let now = nowMs()
        if var t = recurringTasks[id] {
            t.lastFiredAt = now
            t.nextFireAt = nextRecurringFireTime(
                firedAt: now, intervalSeconds: t.intervalSeconds, now: now)
            recurringTasks[id] = t
            persistRecurringTasks()
        }
    }

    private static let recurringTasksDefaultsKey = "juancode.recurringTasks.v1"

    private func persistRecurringTasks() {
        let list = Array(recurringTasks.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.recurringTasksDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.recurringTasksDefaultsKey)
        }
    }

    private func restoreRecurringTasks() {
        guard let data = UserDefaults.standard.data(forKey: Self.recurringTasksDefaultsKey),
              let list = try? JSONDecoder().decode([RecurringTask].self, from: data) else { return }
        for task in list { recurringTasks[task.id] = task }
        if recurringTasks.values.contains(where: \.enabled) { startScheduleLoop() }
    }

    // MARK: - Prompt templates (juancode-2vd)
    //
    // Saved, reusable prompts surfaced through the ⌘K palette. Persisted to
    // UserDefaults as a JSON-encoded array (mirroring tracked PRs / recurring
    // tasks). CRUD goes through the helpers below, each of which re-persists; the
    // palette UI binds to `promptTemplates` and calls insert/submit.

    private static let promptTemplatesDefaultsKey = "juancode.promptTemplates.v1"

    private func persistPromptTemplates() {
        if let data = try? JSONEncoder().encode(promptTemplates) {
            UserDefaults.standard.set(data, forKey: Self.promptTemplatesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.promptTemplatesDefaultsKey)
        }
    }

    private func restorePromptTemplates() {
        guard let data = UserDefaults.standard.data(forKey: Self.promptTemplatesDefaultsKey),
              let list = try? JSONDecoder().decode([PromptTemplate].self, from: data) else { return }
        promptTemplates = list
    }

    /// Create a new template and persist. Returns the stored value.
    @discardableResult
    func addTemplate(title: String, body: String) -> PromptTemplate {
        let now = nowMs()
        let t = PromptTemplate(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               body: body, createdAt: now, updatedAt: now)
        promptTemplates.append(t)
        persistPromptTemplates()
        return t
    }

    /// Edit an existing template's title/body in place (bumps `updatedAt`) and persist.
    func updateTemplate(_ id: String, title: String, body: String) {
        guard let i = promptTemplates.firstIndex(where: { $0.id == id }) else { return }
        promptTemplates[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        promptTemplates[i].body = body
        promptTemplates[i].updatedAt = nowMs()
        persistPromptTemplates()
    }

    func deleteTemplate(_ id: String) {
        promptTemplates.removeAll { $0.id == id }
        persistPromptTemplates()
    }

    /// The folder the palette acts in: the selected session's cwd, else the default.
    private var promptPaletteCwd: String {
        if let sel = selection,
           let meta = (sessions + externalSessions).first(where: { $0.id == sel }) {
            return meta.cwd
        }
        return Config.defaultCwd
    }

    /// Insert a template's body into the active session's composer without sending,
    /// so the user can tweak it first. Falls back to seeding a fresh Claude session
    /// when the current folder has no live session (mirrors `workOnIssue`).
    func insertTemplate(_ template: PromptTemplate) {
        applyTemplate(template, submit: false)
    }

    /// Insert a template's body and submit it immediately.
    func submitTemplate(_ template: PromptTemplate) {
        applyTemplate(template, submit: true)
    }

    /// Shared insert/submit path. A live session in the resolved folder receives the
    /// body (pasted, optionally with the submitting Enter); otherwise a fresh Claude
    /// session is spawned, seeded with the prompt as its initial input.
    private func applyTemplate(_ template: PromptTemplate, submit: Bool) {
        let body = template.body
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cwd = promptPaletteCwd
        if let session = focusedLiveSession(in: cwd) {
            if submit { session.submit(body) } else { session.insert(body) }
            selection = session.id
            terminalFocusToken += 1
            return
        }
        // No live session in this folder — seed a fresh Claude session with the
        // prompt as its initial input. A brand-new session has no composer to
        // insert-without-sending into, so this path always submits (matches
        // `workOnIssue`'s fallback).
        Task {
            await create(provider: .claude, cwd: cwd, skipPermissions: true,
                         isolateWorktree: false, initialInput: body)
        }
    }

    // MARK: - Session templates (juancode-a2r)
    //
    // Saved launch presets surfaced through the templates sheet. Persisted to
    // UserDefaults as a JSON-encoded array (mirroring prompt templates / tracked
    // PRs). CRUD goes through the helpers below, each of which re-persists; the
    // sheet binds to `sessionTemplates` and calls `launchSessionTemplate`.

    private static let sessionTemplatesDefaultsKey = "juancode.sessionTemplates.v1"

    private func persistSessionTemplates() {
        if let data = try? JSONEncoder().encode(sessionTemplates) {
            UserDefaults.standard.set(data, forKey: Self.sessionTemplatesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionTemplatesDefaultsKey)
        }
    }

    private func restoreSessionTemplates() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionTemplatesDefaultsKey),
              let list = try? JSONDecoder().decode([SessionTemplate].self, from: data) else { return }
        sessionTemplates = list
    }

    /// Create a new session template and persist. Returns the stored value.
    @discardableResult
    func addSessionTemplate(name: String, provider: ProviderId, cwd: String,
                            skipPermissions: Bool, isolateWorktree: Bool,
                            initialPrompt: String) -> SessionTemplate {
        let now = nowMs()
        let t = SessionTemplate(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider, cwd: cwd.trimmingCharacters(in: .whitespaces),
            skipPermissions: skipPermissions, isolateWorktree: isolateWorktree,
            initialPrompt: initialPrompt, createdAt: now, updatedAt: now)
        sessionTemplates.append(t)
        persistSessionTemplates()
        return t
    }

    /// Edit an existing template in place (bumps `updatedAt`) and persist.
    func updateSessionTemplate(_ id: String, name: String, provider: ProviderId, cwd: String,
                               skipPermissions: Bool, isolateWorktree: Bool, initialPrompt: String) {
        guard let i = sessionTemplates.firstIndex(where: { $0.id == id }) else { return }
        sessionTemplates[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTemplates[i].provider = provider
        sessionTemplates[i].cwd = cwd.trimmingCharacters(in: .whitespaces)
        sessionTemplates[i].skipPermissions = skipPermissions
        sessionTemplates[i].isolateWorktree = isolateWorktree
        sessionTemplates[i].initialPrompt = initialPrompt
        sessionTemplates[i].updatedAt = nowMs()
        persistSessionTemplates()
    }

    func deleteSessionTemplate(_ id: String) {
        sessionTemplates.removeAll { $0.id == id }
        persistSessionTemplates()
    }

    /// Spawn `count` sessions from a template. Each is a normal `create` — same
    /// spawn path a hand-made session takes — seeded with the template's prompt (if
    /// any). Only the first is selected (so a fan-out of N doesn't thrash focus);
    /// worktree isolation is honoured per session, so N copies land in N worktrees.
    func launchSessionTemplate(_ template: SessionTemplate, count: Int = 1) {
        let n = max(1, count)
        let seed = template.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            for i in 0..<n {
                await create(provider: template.provider, cwd: template.cwd,
                             skipPermissions: template.skipPermissions,
                             isolateWorktree: template.isolateWorktree,
                             initialInput: seed.isEmpty ? nil : seed,
                             select: i == 0)
            }
        }
    }

    // MARK: - Database recovery (juancode-4zk)

    /// Move the unopenable on-disk database aside so a fresh one is created on the
    /// next launch, preserving the old file (and its `-wal`/`-shm` siblings) as a
    /// timestamped `.corrupt-<ms>` backup for forensics. Returns the backup path on
    /// success. Only meaningful in the degraded (in-memory-fallback) state.
    @discardableResult
    func resetCorruptDatabase() -> String? {
        guard let path = corruptDbPath else { return nil }
        let fm = FileManager.default
        let stamp = String(nowMs())
        let backup = "\(path).corrupt-\(stamp)"
        var movedMain = false
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            guard fm.fileExists(atPath: src) else { continue }
            do {
                try fm.moveItem(atPath: src, toPath: backup + suffix)
                if suffix.isEmpty { movedMain = true }
            } catch {
                errorMessage = "Couldn't move aside \(src): \(error)"
                return nil
            }
        }
        // If the main file didn't exist at all, the open failure was the directory
        // itself (permissions / disk) — nothing to reset; tell the caller.
        return movedMain ? backup : nil
    }

    private func startScheduleLoop() {
        guard scheduleLoop == nil else { return }
        scheduleLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fireDueRecurringTasksOnce()
                try? await Task.sleep(for: self?.scheduleTickInterval ?? .seconds(30))
            }
        }
    }

    /// One scheduler pass: spawn a fresh session for every due task and reschedule it.
    func fireDueRecurringTasksOnce() async {
        let now = nowMs()
        for task in dueRecurringTasks(Array(recurringTasks.values), now: now) {
            // The task may have been removed/paused while we were off-actor.
            guard let current = recurringTasks[task.id], current.enabled else { continue }
            // Spawn a fresh session in the project, seeded with the prompt. Don't steal
            // focus — recurring runs are unattended background work.
            _ = await create(provider: current.provider, cwd: current.cwd,
                             skipPermissions: current.skipPermissions, isolateWorktree: false,
                             initialInput: current.prompt, select: false)
            if var t = recurringTasks[task.id] {
                t.lastFiredAt = now
                t.nextFireAt = nextRecurringFireTime(
                    firedAt: now, intervalSeconds: t.intervalSeconds, now: now)
                recurringTasks[task.id] = t
            }
        }
        persistRecurringTasks()
    }

    // MARK: - Periodic health checks (juancode-0me pillar 3 / juancode-02k)

    /// Unhealthy sessions surfaced by the latest health sweep, keyed by session id.
    /// Drives the Session Health panel + its toolbar badge. Only sessions we've seen
    /// live this run are considered, so the pile of historical exited sessions in the
    /// store doesn't flood it — we flag the ones the orchestration loops were actually
    /// driving when they died or stalled.
    var sessionHealth: [String: SessionHealthReport] = [:]

    /// Health alerts the user has dismissed this run, so the sweep doesn't keep
    /// re-raising them. Cleared for a session once it recovers (so a later re-failure
    /// surfaces again).
    @ObservationIgnored private var dismissedHealth: Set<String> = []
    /// Health states already written to the activity log, so a still-unhealthy
    /// session isn't re-logged every 30s sweep — only edges land in the file.
    @ObservationIgnored private var loggedHealthStates: [String: SessionHealthState] = [:]
    /// Session ids we've observed live at least once this run — the set the sweep is
    /// allowed to flag. A session must have come up before we'll report it dead/stale.
    @ObservationIgnored private var everLive: Set<String> = []
    /// How often the health sweep runs. Coarse — sessions dying/stalling is a
    /// minutes-scale concern, and `onExit` already handles the live UI refresh.
    private let healthTickInterval: Duration = .seconds(30)
    @ObservationIgnored private var healthLoop: Task<Void, Never>?

    /// Unhealthy sessions, newest-failing-id first, for the health panel + badge.
    var unhealthySessions: [SessionHealthReport] {
        sessionHealth.values.sorted { $0.id < $1.id }
    }

    private func startHealthLoop() {
        guard healthLoop == nil else { return }
        healthLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.runHealthCheckOnce()
                try? await Task.sleep(for: self?.healthTickInterval ?? .seconds(30))
            }
        }
    }

    /// One health pass: reconcile the store against the live registry and republish
    /// the set of dead/stale sessions. Idempotent and cheap, so the tracked-PR /
    /// reactivate paths can call it directly to refresh the panel without waiting for
    /// the next tick.
    func runHealthCheckOnce() {
        let now = nowMs()
        // Remember anything currently live so we only ever flag sessions we were
        // actually driving — not the backlog of long-dead history.
        for meta in sessions where isLive(meta.id) { everLive.insert(meta.id) }
        let inputs: [SessionHealthInput] = sessions.compactMap { meta in
            guard everLive.contains(meta.id) else { return nil }
            return SessionHealthInput(
                id: meta.id, status: meta.status, isLive: isLive(meta.id),
                activity: activity(meta.id), lastOutputMs: meta.updatedAt,
                resumable: meta.cliSessionId != nil, dormant: meta.dormant)
        }
        let reports = SessionHealth.sweep(inputs, nowMs: now)
        // Durable trail: log each report once per state change, not on every sweep.
        for r in reports where loggedHealthStates[r.id] != r.state {
            appState.activityLog.log("health", sessionId: r.id,
                                     project: sessions.first { $0.id == r.id }?.cwd ?? "",
                                     fields: ["state": r.state.rawValue])
        }
        loggedHealthStates = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0.state) })
        // Keep dismissals only for sessions that are still unhealthy; a recovered one
        // drops its dismissal so a future failure re-alerts.
        dismissedHealth.formIntersection(Set(reports.map(\.id)))
        sessionHealth = Dictionary(
            uniqueKeysWithValues: reports
                .filter { !dismissedHealth.contains($0.id) }
                .map { ($0.id, $0) })
    }

    /// Reactivate a dead session from the health panel, then re-sweep so its alert
    /// clears (or, if it couldn't be resumed, stays with an error surfaced).
    func reactivateUnhealthy(_ id: String) {
        Task {
            await reactivate(id)
            runHealthCheckOnce()
        }
    }

    /// Dismiss a health alert. It won't re-raise unless the session recovers and then
    /// fails again (see `runHealthCheckOnce`).
    func dismissHealth(_ id: String) {
        dismissedHealth.insert(id)
        sessionHealth[id] = nil
    }

    // MARK: - Changes panel (working-tree diff + inline comments + git actions) — juancode-3bq

    /// Per-session working-tree diff cache, loaded lazily by the ChangesPanel and
    /// refreshed on demand. Mirrors the web's per-session `useQuery(["diff", …])`.
    var diffBySession: [String: DiffResult] = [:]
    /// Per-session git state (branch / ahead / dirty / remote) backing the git CTAs.
    var gitStateBySession: [String: GitState] = [:]
    /// Per-session inline review comments. Held in-memory (in-process, no server
    /// round-trip) — they're a staging area pasted into the agent on "submit".
    var commentsBySession: [String: [DiffComment]] = [:]
    /// Per-session archive of comment batches already sent to the agent (juancode-qce.3).
    /// A sent review no longer silently vanishes — it moves here so it stays retrievable
    /// (restore re-stages it) instead of being dropped on submit.
    private(set) var archivedCommentsBySession: [String: [DiffComment]] = [:]
    /// Sessions whose diff is currently loading, so the panel can show a spinner.
    var diffLoading: Set<String> = []
    /// A transient git-action status line per session (commit/push result or error).
    var gitNoteBySession: [String: GitNote] = [:]

    private var diffInFlight: Set<String> = []

    /// Cheapest whole-tree change summary per session, recomputed when the agent
    /// settles a turn in a dirty tree. Drives the sidebar review badge + the
    /// session-view banner. Nil / absent ⇒ clean, no badge.
    private(set) var changeStatBySession: [String: ChangeStat] = [:]
    /// The change signature each session's Changes panel last showed — the debounce
    /// key. A badge appears only while the latest stat differs from this.
    private var viewedChangeSignatureBySession: [String: String] = [:]

    /// Per-session 'Review with Claude' result (juancode-7ha). The last AI review
    /// pass over the working-tree diff, cached so findings stay overlaid until the
    /// next run — the native analogue of the web's `useQuery(["review", …])`.
    var reviewBySession: [String: ReviewResult] = [:]
    /// Sessions whose review pass is currently running, so the panel can show a
    /// "Reviewing…" spinner and disable the button.
    var reviewRunning: Set<String> = []

    /// What the ChangesPanel is diffing for a session (juancode-49w): the working
    /// tree (default), the current branch vs its base, or an existing PR. Held per
    /// session so the choice survives view rebuilds and `Refresh`.
    enum ChangesSource: Equatable, Sendable {
        case workingTree
        /// Current branch vs its base/merge-base (base inferred when nil).
        case base
        /// An existing PR's diff, loaded via `gh pr diff`.
        case pr(PullRequest)
        /// A single commit's diff (juancode-5u2). Full sha + subject for labels.
        case commit(sha: String, subject: String)
    }
    /// Per-session diff source. Absent ⇒ `.workingTree`.
    var changesSourceBySession: [String: ChangesSource] = [:]
    /// The base ref a `.base` diff resolved to (e.g. `origin/main`), for the header.
    var changesBaseBySession: [String: String] = [:]
    /// A per-session diff-load error (base/PR fetch failures), shown in the panel.
    var changesErrorBySession: [String: String] = [:]
    /// Per-session failing-CI logs for the PR currently shown in its ChangesPanel,
    /// fetched on demand via `gh run view --log-failed` (juancode-49w).
    var prCiLogsBySession: [String: String] = [:]
    /// Sessions whose CI-log fetch is in flight (for the banner spinner).
    private var prCiLogsLoading: Set<String> = []
    /// Recent commits for the ChangesPanel's commit picker (juancode-5u2), per session.
    var recentCommitsBySession: [String: [RecentCommit]] = [:]
    /// Sessions whose commit-list fetch is in flight (for the picker spinner).
    private var recentCommitsLoading: Set<String> = []

    struct GitNote: Equatable { var ok: Bool; var text: String }

    func diff(_ id: String) -> DiffResult? { diffBySession[id] }
    func gitState(_ id: String) -> GitState? { gitStateBySession[id] }
    func comments(_ id: String) -> [DiffComment] { commentsBySession[id] ?? [] }
    func review(_ id: String) -> ReviewResult? { reviewBySession[id] }
    func isReviewing(_ id: String) -> Bool { reviewRunning.contains(id) }
    func changesSource(_ id: String) -> ChangesSource { changesSourceBySession[id] ?? .workingTree }
    func changesBaseLabel(_ id: String) -> String? { changesBaseBySession[id] }
    func changesError(_ id: String) -> String? { changesErrorBySession[id] }
    func prCiLogs(_ id: String) -> String? { prCiLogsBySession[id] }
    func isLoadingPrCiLogs(_ id: String) -> Bool { prCiLogsLoading.contains(id) }
    func recentCommits(_ id: String) -> [RecentCommit] { recentCommitsBySession[id] ?? [] }
    func isLoadingRecentCommits(_ id: String) -> Bool { recentCommitsLoading.contains(id) }

    /// Load (or refresh) the last ~50 commits for the ChangesPanel's commit picker
    /// (juancode-5u2). Off the main actor; coalesces concurrent requests.
    func loadRecentCommits(_ id: String) {
        guard let cwd = gitCwd(of: id), !recentCommitsLoading.contains(id) else { return }
        recentCommitsLoading.insert(id)
        Task {
            let commits = await Task.detached(priority: .utility) {
                await listRecentCommits(cwd, limit: 50)
            }.value
            recentCommitsBySession[id] = commits
            recentCommitsLoading.remove(id)
        }
    }

    /// Fetch the failing-step CI logs for a PR shown in a session's ChangesPanel
    /// (`gh run view --log-failed` for each red Actions check). Off the main actor;
    /// coalesces. A "no logs" result is shown rather than left blank.
    func loadPrCiLogs(_ id: String, number: Int) {
        guard let cwd = cwd(of: id), !prCiLogsLoading.contains(id) else { return }
        prCiLogsLoading.insert(id)
        Task {
            let logs = await Task.detached(priority: .utility) {
                await getFailedCheckLogs(cwd, number: number)
            }.value
            prCiLogsBySession[id] = logs.isEmpty ? "No failing-step logs available." : logs
            prCiLogsLoading.remove(id)
        }
    }

    /// The cwd a session's changes panel operates on (its own working directory).
    private func cwd(of id: String) -> String? {
        liveSession(id)?.meta.cwd ?? appState.store.get(id)?.cwd
    }

    /// The working folder of a session — for the ChangesPanel's PR picker and CI
    /// affordances (open PRs are keyed by folder cwd).
    func sessionCwd(_ id: String) -> String? { cwd(of: id) }

    // MARK: - Agent-created worktrees (juancode-0sw)

    /// Worktrees the agent inside a pty created for itself (Claude Code's
    /// EnterWorktree → `<repo>/.claude/worktrees/<name>`), detected by matching the
    /// session's child pid against worktree lock reasons. Kept out of
    /// `meta.worktreePath` deliberately: that field means "juancode owns this
    /// worktree" and drives removal on session close, while these belong to the
    /// agent. Survives session exit so a finished session's diff stays reviewable.
    private var agentWorktreeBySession: [String: String] = [:]

    /// The agent-created worktree a session is working in, if one was detected.
    func agentWorktree(_ id: String) -> String? { agentWorktreeBySession[id] }

    /// The directory git operations for a session should run in: the worktree its
    /// agent entered when one is detected, else the session cwd. Every diff-rooted
    /// action (diff, commit, push, PR, revert, review, editor) resolves through
    /// this so the panel follows the tree the agent actually edits.
    private func gitCwd(of id: String) -> String? {
        agentWorktreeBySession[id] ?? cwd(of: id)
    }

    /// Re-detect the session's agent-created worktree, off the main actor. Cheap
    /// (one `git worktree list`), so callers run it on every diff/badge refresh —
    /// the agent can enter or leave a worktree at any point mid-session. Only
    /// resolvable while the session runs (the pid match needs a live child);
    /// afterwards the last known value is kept.
    private func resolveAgentWorktree(_ id: String) async {
        guard let session = liveSession(id), let pid = session.childPid else { return }
        let cwd = session.meta.cwd
        let detected = await Task.detached(priority: .utility) {
            await detectAgentWorktree(cwd, childPid: pid)
        }.value
        let previous = agentWorktreeBySession[id]
        agentWorktreeBySession[id] = detected
        // The diff watcher is rooted at gitCwd — re-arm it when that just moved.
        if detected != previous, changesWatchTokens[id] != nil {
            stopWatchingChanges(id)
            startWatchingChanges(id)
        }
    }

    /// Switch what a session's ChangesPanel diffs and reload. No-op when the source
    /// is unchanged. Clears the stale diff so the panel shows a spinner, not the
    /// previous source's files, while the new one loads.
    func setChangesSource(_ id: String, _ source: ChangesSource) {
        guard changesSource(id) != source else { return }
        changesSourceBySession[id] = source
        diffBySession[id] = nil
        changesErrorBySession[id] = nil
        prCiLogsBySession[id] = nil
        loadChanges(id)
    }

    /// The effective working directory an agent edits in — its linked worktree when
    /// it runs in one, else its cwd. What the change badge measures.
    private func effectiveCwd(of id: String) -> String? {
        liveSession(id)?.meta.effectiveCwd ?? appState.store.get(id)?.effectiveCwd
    }

    /// The review badge for a session: the latest change summary, but only while it
    /// differs from what its Changes panel last showed (else nil — cleared/clean).
    func changeBadge(_ id: String) -> ChangeStat? {
        let stat = changeStatBySession[id]
        guard changeBadgeVisible(latest: stat, viewedSignature: viewedChangeSignatureBySession[id])
        else { return nil }
        return stat
    }

    /// Recompute a session's change summary off the main actor (the busy → settled
    /// edge). If its Changes panel is already open on the working tree, mark the
    /// result seen so a session you're actively reviewing never re-badges itself.
    private func refreshChangeStat(_ id: String) {
        guard effectiveCwd(of: id) != nil else { return }
        Task {
            await resolveAgentWorktree(id)
            guard let cwd = agentWorktreeBySession[id] ?? effectiveCwd(of: id) else { return }
            let stat = await Task.detached(priority: .utility) {
                await computeChangeStat(cwd)
            }.value
            changeStatBySession[id] = stat.isEmpty ? nil : stat
            if !stat.isEmpty, isChangesPanelOpen(for: id) {
                viewedChangeSignatureBySession[id] = stat.signature
            }
        }
    }

    /// Whether `id`'s Changes panel is the visible, working-tree source right now —
    /// i.e. the user is already looking at this session's diff.
    private func isChangesPanelOpen(for id: String) -> Bool {
        guard selection == id else { return false }
        let d = UserDefaults.standard
        let shown = d.object(forKey: "session.sidePanel.shown") as? Bool ?? true
        let onChanges = (d.string(forKey: "session.sidePanel.tab") ?? "Changes") == "Changes"
        guard shown, onChanges else { return false }
        if case .workingTree = changesSource(id) { return true }
        return false
    }

    /// Record that a session's changes have been viewed — clears its badge by taking
    /// the latest signature as seen. Called when the Changes panel appears.
    func markChangesViewed(_ id: String) {
        viewedChangeSignatureBySession[id] = changeStatBySession[id]?.signature ?? ""
    }

    /// Open the Changes panel for a session pre-loaded on the working tree and clear
    /// its review badge. The action behind the sidebar badge, the session banner, and
    /// the "Open Changes for current session" shortcut.
    func openChanges(for id: String) {
        setChangesSource(id, .workingTree)
        let d = UserDefaults.standard
        d.set("Changes", forKey: "session.sidePanel.tab")
        d.set(true, forKey: "session.sidePanel.shown")
        markChangesViewed(id)
        // Explicit open → let the diff pane grab the keyboard so j/k/n/p/r/c work
        // immediately. A plain session-switch appear does not request this.
        requestChangesFocus(id)
    }

    /// Load (or refresh) the diff + git state for a session, off the main actor
    /// (both shell out). The diff source (working tree / base branch / PR) is read
    /// from `changesSource`. Coalesces concurrent calls. Mirrors `loadPrs`.
    func loadChanges(_ id: String) {
        guard cwd(of: id) != nil, !diffInFlight.contains(id) else { return }
        let source = changesSource(id)
        diffInFlight.insert(id)
        diffLoading.insert(id)
        Task {
            // The agent may have entered (or left) its own worktree since the last
            // load — re-resolve so the diff follows the tree it actually edits.
            await resolveAgentWorktree(id)
            guard let cwd = gitCwd(of: id) else {
                diffLoading.remove(id); diffInFlight.remove(id); return
            }
            async let stateTask = Task.detached(priority: .utility) { await getGitState(cwd) }.value
            let loaded = await Task.detached(priority: .utility) { await loadDiffForSource(cwd, source) }.value
            let state = await stateTask
            if let d = loaded.diff { diffBySession[id] = d }
            if let base = loaded.base { changesBaseBySession[id] = base }
            changesErrorBySession[id] = loaded.error
            gitStateBySession[id] = state
            diffLoading.remove(id)
            diffInFlight.remove(id)
        }
    }

    /// Begin live-watching a session's worktree while its Changes panel is open, so
    /// external edits (the agent mid-turn, an embedded editor, the user) refresh the
    /// diff within ~1s without a manual Refresh. Shares one FSEvents stream per
    /// worktree path across sessions; idempotent per session.
    func startWatchingChanges(_ id: String) {
        guard changesWatchTokens[id] == nil, let cwd = gitCwd(of: id) else { return }
        let token = worktreeWatchers.watch(path: cwd) { [weak self] in
            Task { @MainActor in self?.onWorktreeChanged(sessionId: id, path: cwd) }
        }
        if let token { changesWatchTokens[id] = token }
    }

    /// Stop live-watching a session's worktree (its Changes panel closed or the
    /// session went away). Idempotent.
    func stopWatchingChanges(_ id: String) {
        changesWatchTokens.removeValue(forKey: id)?.cancel()
    }

    private func onWorktreeChanged(sessionId: String, path: String) {
        // A base/PR/commit diff isn't moved by local edits — only re-diff when the
        // panel is showing the working tree, so background sources don't re-shell git.
        if case .workingTree = changesSource(sessionId) {
            loadChanges(sessionId)
        }
        refreshWorktreeStatus(path)
    }

    private func refreshWorktreeStatus(_ path: String) {
        Task {
            let entries = await Task.detached(priority: .utility) {
                await computeWorktreeStatus(path)
            }.value
            worktreeStatusByPath[path] = entries
        }
    }

    // MARK: - Quick Open (⌘P) — fuzzy file open scoped to the session's worktree

    /// Open the Quick Open palette for the selected session, scoped to its effective
    /// worktree. Serves the cached file list instantly (a 10k-file repo opens with no
    /// wait), refreshes the dirty snapshot so the reveal-in-Changes action is accurate,
    /// re-indexes in the background on a cold cache, and starts an FSEvents watch that
    /// keeps the index fresh while the tree changes underneath.
    func openQuickOpen() {
        guard let sel = selection, let cwd = effectiveCwd(of: sel) else { return }
        quickOpenCwd = cwd
        quickOpenFiles = fileIndex.files(for: cwd) ?? []
        watchFileIndex(cwd)
        refreshWorktreeStatus(cwd)
        if !fileIndex.isCached(cwd) { loadFileIndex(cwd) }
        showingQuickOpen = true
    }

    /// (Re)index a worktree with `git ls-files` off the main actor, then publish the
    /// snapshot if the palette is still on that worktree. Coalesces trivially: a change
    /// burst re-arms via the watcher's debounce, not per event.
    private func loadFileIndex(_ path: String) {
        quickOpenLoading = true
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                await listTrackedFiles(path)
            }.value
            fileIndex.store(files, for: path)
            if quickOpenCwd == path { quickOpenFiles = files }
            quickOpenLoading = false
        }
    }

    /// Subscribe once per worktree to the shared FSEvents watcher: on change, drop the
    /// cached list and re-index while the palette is open on that path (debounced by the
    /// watcher). Idempotent — a second Quick Open on the same worktree reuses the token.
    private func watchFileIndex(_ path: String) {
        guard fileIndexWatchTokens[path] == nil else { return }
        let token = worktreeWatchers.watch(path: path) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fileIndex.invalidate(path)
                if self.showingQuickOpen, self.quickOpenCwd == path { self.loadFileIndex(path) }
            }
        }
        if let token { fileIndexWatchTokens[path] = token }
    }

    /// Whether a Quick Open result has uncommitted changes — drives the "reveal in
    /// Changes" affordance. Reads the watched porcelain snapshot for the palette's
    /// worktree; `path` is worktree-relative, matching `WorktreeStatusEntry.path`.
    func quickOpenIsDirty(_ path: String) -> Bool {
        guard let cwd = quickOpenCwd else { return false }
        return worktreeStatus(cwd).contains { $0.path == path }
    }

    /// Open a Quick Open result in the session's editor pane (nvim/$EDITOR), rooted in
    /// its worktree with the file open. Routes through the file-taking editor path.
    func quickOpenInEditor(_ path: String) {
        guard let sel = selection else { return }
        openEditorSession(sel, file: path)
        showingQuickOpen = false
    }

    /// Reveal a (dirty) Quick Open result in the Changes panel — opens the working-tree
    /// diff for the selected session and clears its review badge.
    func quickOpenReveal(_ path: String) {
        guard let sel = selection else { return }
        openChanges(for: sel)
        showingQuickOpen = false
    }

    /// Insert a Quick Open result's worktree-relative path into the selected session's
    /// prompt (no submit), so the user can reference the file in their next message.
    func quickOpenCopyPath(_ path: String) {
        guard let sel = selection, let session = liveSession(sel) else { return }
        session.insert(path)
        selection = sel
        focusTerminal()
        showingQuickOpen = false
    }

    // MARK: - File tree (Files side-panel tab)

    /// Ensure a worktree's file tree is loaded and live-refresh it while a session's
    /// Files tab is open: on change the shared per-path FSEvents stream invalidates
    /// the Quick Open file index, re-lists, refolds the tree, and refreshes the
    /// change snapshot the rows decorate from. Idempotent per session.
    func startWatchingFileTree(_ id: String, path: String) {
        if fileTreeByPath[path] == nil { loadFileTree(path) }
        refreshWorktreeStatus(path)
        guard fileTreeWatchTokens[id] == nil else { return }
        let token = worktreeWatchers.watch(path: path) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fileIndex.invalidate(path)
                self.loadFileTree(path)
                self.refreshWorktreeStatus(path)
            }
        }
        if let token { fileTreeWatchTokens[id] = token }
    }

    /// Stop live-refreshing a session's file tree (its Files tab closed or the
    /// session went away). The built tree stays cached for an instant re-open.
    func stopWatchingFileTree(_ id: String) {
        fileTreeWatchTokens.removeValue(forKey: id)?.cancel()
    }

    /// (Re)list a worktree — through the shared Quick Open file index so the two
    /// surfaces never shell out twice for the same snapshot — and fold the flat
    /// list into the directory tree off the main actor.
    private func loadFileTree(_ path: String) {
        fileTreeLoading.insert(path)
        Task {
            let files: [String]
            if let cached = fileIndex.files(for: path) {
                files = cached
            } else {
                files = await Task.detached(priority: .userInitiated) {
                    await listTrackedFiles(path)
                }.value
                fileIndex.store(files, for: path)
            }
            let tree = await Task.detached(priority: .userInitiated) {
                buildPathTree(files)
            }.value
            fileTreeByPath[path] = tree
            fileTreeLoading.remove(path)
        }
    }

    /// Toggle the session's right-side panel onto the Files tab (the file-tree
    /// sidebar). Mirrors `toggleChangesPanel`: hides only when Files is already the
    /// visible tab — from another tab it switches instead.
    func toggleFileTreePanel() {
        let d = UserDefaults.standard
        let shown = d.object(forKey: "session.sidePanel.shown") as? Bool ?? true
        let onFiles = (d.string(forKey: "session.sidePanel.tab") ?? "Changes") == "Files"
        if shown && onFiles {
            d.set(false, forKey: "session.sidePanel.shown")
        } else {
            d.set("Files", forKey: "session.sidePanel.tab")
            d.set(true, forKey: "session.sidePanel.shown")
        }
    }

    /// Spawn the user's real editor (`$VISUAL`/`$EDITOR`, default nvim) on `file`,
    /// confined to the session's cwd, via an ephemeral pty. Returns the live pty for
    /// the overlay to render + drive, or nil if there's no cwd or the spawn/path
    /// check fails (a status note is set on failure). Mirrors the web `openEditor`
    /// handshake — the native overlay renders the returned pty directly (no WS hop).
    func openEditor(_ id: String, file: String, cols: Int, rows: Int) -> EphemeralPty? {
        guard let cwd = gitCwd(of: id) else {
            gitNoteBySession[id] = GitNote(ok: false, text: "No working directory for this session.")
            return nil
        }
        do {
            return try appState.ephemeral.openEditor(cwd: cwd, file: file, cols: cols, rows: rows)
        } catch {
            let text: String
            switch error {
            case EphemeralPtyError.outsideWorkingDir: text = "File is outside the working directory."
            case EphemeralPtyError.spawnFailed: text = "Couldn't launch the editor."
            default: text = String(describing: error)
            }
            gitNoteBySession[id] = GitNote(ok: false, text: text)
            return nil
        }
    }

    /// Open `file` in the user's real editor as the floating overlay (`EditorHost`).
    /// Spawns the ephemeral pty now so the overlay binds a live pty; no-op if one's
    /// already open or the spawn fails (`openEditor` sets a git note). The overlay
    /// resizes the pty to its real grid on appear, so the seed cols/rows are nominal.
    func openEditorOverlay(_ sessionId: String, file: String) {
        guard editing == nil else { return }
        if let pty = openEditor(sessionId, file: file, cols: 80, rows: 24) {
            editing = EditorTarget(sessionId: sessionId, file: file, pty: pty)
        }
    }

    /// Dismiss the editor overlay (idempotent) and refresh the session's diff, since
    /// the editor may have changed the file. Mirrors the web `onClose` → refetch.
    func closeEditorOverlay(_ id: UUID) {
        guard let target = editing, target.id == id else { return }
        editing = nil
        loadChanges(target.sessionId)
    }

    // MARK: - Bottom terminal panel (per-workdir)

    /// VS Code-style bottom shell terminals, keyed by FOLDER cwd (not session id):
    /// every session in a folder shares the same set of terminals, so switching
    /// between sessions in one folder keeps the terminals alive and identical. The
    /// pure tab/pane layout lives in `TerminalPanelModel`; the live shell ptys are
    /// held alongside it, keyed by pane id. (Cross-session-switch persistence
    /// niceties are tracked separately in juancode-iwi.)
    var terminalPanels: [String: TerminalPanelModel] = [:]
    /// Live shell ptys for every open pane, keyed by pane id. Shared across all
    /// folders; entries are removed + killed when their pane closes.
    private var shellPtys: [TerminalPaneID: EphemeralPty] = [:]

    /// Whether the bottom shell-terminal panel is shown. Global (shared across all
    /// sessions) and persisted under the key the session header used, so it survives
    /// restarts. Toggled from the header CTA or the ⌃T global shortcut.
    var bottomTerminalShown: Bool = UserDefaults.standard.bool(forKey: "session.bottomPanel.shown") {
        didSet { UserDefaults.standard.set(bottomTerminalShown, forKey: "session.bottomPanel.shown") }
    }

    /// Toggle the bottom terminal panel. When opening it, seed the first shell in the
    /// selected session's folder if that folder has none yet (mirrors the header
    /// button). No-op seeding if nothing is selected.
    func toggleBottomTerminal() {
        // Panel transition: the terminal coordinators must hold the intermediate
        // grids this relayout produces and settle once (juancode-1th.2). 500ms
        // spans the 200ms slide plus both settle windows, so the animated reflow
        // runs the same lockstep+settle path as a divider drag.
        LayoutTransitionGate.shared.begin(for: .milliseconds(500))
        // Animated: the panel is kept mounted and slides to/from zero height (see
        // SessionContainer) — the surface NSViews are never recreated. easeInOut,
        // not a spring: overshoot would fire extra grid flaps into the ptys.
        withAnimation(.easeInOut(duration: 0.2)) { bottomTerminalShown.toggle() }
        if !bottomTerminalShown {
            // The collapsed shell must not keep first-responder status (it would
            // type into an invisible terminal) — hand focus to the main terminal.
            focusTerminal()
        }
        guard bottomTerminalShown,
              let id = selection,
              let cwd = sessions.first(where: { $0.id == id })?.cwd,
              terminalPanel(cwd).isEmpty
        else { return }
        openTerminalTab(cwd: cwd)
    }

    /// The terminal panel model for `cwd` (empty if none opened yet).
    func terminalPanel(_ cwd: String) -> TerminalPanelModel { terminalPanels[cwd] ?? .init() }

    /// The live shell pty backing `pane`, if still alive.
    func shellPty(_ pane: TerminalPaneID) -> EphemeralPty? { shellPtys[pane] }

    /// Open a new shell terminal tab in `cwd`. Spawns the user's `$SHELL` (default
    /// zsh, `-i`) in that folder via the ephemeral-pty service and makes it active.
    func openTerminalTab(cwd: String) {
        var panel = terminalPanel(cwd)
        let pane = panel.addTab()
        if spawnShell(for: pane, cwd: cwd) {
            terminalPanels[cwd] = panel
        }
    }

    /// Split the active tab in `cwd` into two side-by-side panes, spawning a shell
    /// for the new pane. No-op if there's no active tab or it's already split.
    func splitActiveTerminal(cwd: String) {
        var panel = terminalPanel(cwd)
        guard let pane = panel.splitActiveTab() else { return }
        if spawnShell(for: pane, cwd: cwd) {
            terminalPanels[cwd] = panel
        }
    }

    /// Close a tab in `cwd`, killing its pane ptys.
    func closeTerminalTab(cwd: String, tab: UUID) {
        var panel = terminalPanel(cwd)
        let orphaned = panel.closeTab(tab)
        terminalPanels[cwd] = panel
        for pane in orphaned { killShell(pane) }
    }

    /// Make `tab` the active terminal in `cwd`.
    func selectTerminalTab(cwd: String, tab: UUID) {
        var panel = terminalPanel(cwd)
        panel.selectTab(tab)
        terminalPanels[cwd] = panel
    }

    /// Spawn a shell pty for `pane` in `cwd`; returns false (and notes nothing) if
    /// the spawn fails so the caller can skip persisting the pane.
    private func spawnShell(for pane: TerminalPaneID, cwd: String) -> Bool {
        guard let pty = try? appState.ephemeral.openTerminal(cwd: cwd, cols: 80, rows: 24) else {
            return false
        }
        shellPtys[pane] = pty
        return true
    }

    private func killShell(_ pane: TerminalPaneID) {
        shellPtys.removeValue(forKey: pane)?.kill()
    }

    /// Add an inline comment to a session's staging area. `quote` is the annotated
    /// diff line(s) captured from the rendered diff (with +/- markers) so the review
    /// composer can quote exactly what was highlighted (juancode-ck4).
    func addComment(_ id: String, file: String, side: CommentSide, line: Int, endLine: Int,
                    body: String, quote: String? = nil) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var c = DiffComment(
            id: UUID().uuidString, sessionId: id, file: file, side: side,
            line: min(line, endLine), endLine: max(line, endLine),
            body: trimmed, createdAt: Int(Date().timeIntervalSince1970 * 1000), quote: quote)
        // Comments staged on a commit diff point at that commit (juancode-5u2), so
        // the review composer can label them and the panel can scope rendering.
        if case let .commit(sha, subject) = changesSource(id) {
            c.commitSha = sha
            c.commitSubject = subject
        }
        commentsBySession[id, default: []].append(c)
    }

    /// Remove a staged inline comment.
    func deleteComment(_ id: String, commentId: String) {
        commentsBySession[id]?.removeAll { $0.id == commentId }
    }

    /// Discard the whole review basket for a session without sending (juancode-ck4).
    func discardComments(_ id: String) {
        commentsBySession[id] = []
    }

    /// A session's archived (already-sent) comment batches (juancode-qce.3).
    func archivedComments(_ id: String) -> [DiffComment] { archivedCommentsBySession[id] ?? [] }

    /// Re-stage a session's archived comments so a sent review can be pulled back and
    /// edited/resent — the "not silently vanishing" retrieval path.
    func restoreArchivedComments(_ id: String) {
        let archived = archivedCommentsBySession[id] ?? []
        guard !archived.isEmpty else { return }
        commentsBySession[id, default: []].append(contentsOf: archived)
        archivedCommentsBySession[id] = []
    }

    /// Submit the batched review (juancode-ck4, reworked for juancode-qce.3): compose
    /// the staged line annotations into one deterministic feedback prompt (file:line +
    /// quoted hunk + comment) and deliver it through the per-session MESSAGE QUEUE —
    /// NOT a direct pty paste. The queue flushes on the next idle edge (kicked here in
    /// case the session is already idle), so review feedback never interrupts the agent
    /// mid-turn. The sent batch is archived (retrievable), the basket cleared, the
    /// change badge cleared, and focus returned to the terminal so you watch the agent
    /// respond. No-op without a live session.
    func submitReview(_ id: String) {
        guard let session = liveSession(id) else {
            gitNoteBySession[id] = GitNote(ok: false, text: "Session isn't live — can't send review.")
            return
        }
        let staged = comments(id)
        let prompt = composeReviewFeedback(staged)
        guard !prompt.isEmpty else { return }
        appState.messageQueue.add(id, text: prompt)
        session.kickQueue()
        // Archive instead of dropping, so a sent review stays retrievable.
        if !staged.isEmpty { archivedCommentsBySession[id, default: []].append(contentsOf: staged) }
        commentsBySession[id] = []
        markChangesViewed(id)
        focusTerminal()
    }

    /// Turn one AI review finding into a staged inline comment and drop it from the
    /// overlay (juancode-qce.3) — the "accept" half of the per-finding treatment.
    func acceptFinding(_ id: String, _ finding: ReviewFinding) {
        let line = finding.line ?? 1
        let body: String
        if finding.title.isEmpty { body = finding.note }
        else if finding.note.isEmpty { body = finding.title }
        else { body = "\(finding.title)\n\(finding.note)" }
        addComment(id, file: finding.file, side: finding.side, line: line, endLine: line, body: body)
        dismissFinding(id, finding)
    }

    /// Drop one AI review finding from the overlay without acting on it — "dismiss".
    func dismissFinding(_ id: String, _ finding: ReviewFinding) {
        guard var r = reviewBySession[id] else { return }
        r.findings.removeAll { $0 == finding }
        reviewBySession[id] = r
    }

    /// Accept every finding on `file` as comments (the selected-file batch key).
    func acceptFindings(_ id: String, file: String) {
        for f in (reviewBySession[id]?.findings ?? []).filter({ $0.file == file }) {
            acceptFinding(id, f)
        }
    }

    /// Dismiss every finding on `file` (the selected-file batch key).
    func dismissFindings(_ id: String, file: String) {
        guard var r = reviewBySession[id] else { return }
        r.findings.removeAll { $0.file == file }
        reviewBySession[id] = r
    }

    /// Whether `file` currently has any AI review findings — gates the finding keys.
    func hasFindings(_ id: String, file: String) -> Bool {
        (reviewBySession[id]?.findings ?? []).contains { $0.file == file }
    }

    /// Discard the uncommitted changes to one file (juancode-qce.3) — destructive, so
    /// the UI gates it behind an explicit confirm. Runs the scoped `git checkout` off
    /// the main actor and refreshes the diff.
    func revertFile(_ id: String, path: String) async {
        guard let cwd = gitCwd(of: id) else { return }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try await JuancodeServices.revertFile(cwd, path: path)
            }.value
            gitNoteBySession[id] = GitNote(ok: true, text: "Reverted \(r.path)")
            loadChanges(id)
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
        }
    }

    /// Discard one hunk of a file's uncommitted change (juancode-qce.3) — destructive,
    /// confirm-gated. Reverse-applies exactly that hunk off the main actor.
    func revertHunk(_ id: String, path: String, hunkIndex: Int) async {
        guard let cwd = gitCwd(of: id) else { return }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try await JuancodeServices.revertHunk(cwd, path: path, hunkIndex: hunkIndex)
            }.value
            gitNoteBySession[id] = GitNote(ok: true, text: "Reverted a hunk in \(r.path)")
            loadChanges(id)
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
        }
    }

    /// Run an AI review pass over the session's working-tree diff (juancode-7ha):
    /// feed the diff (+ any staged inline comments as steering context) to the real
    /// `claude` CLI via the existing `BinaryResolver` — same auth/binary as a
    /// session, no shadow HOME — and cache the structured findings to overlay on the
    /// diff. Coalesces concurrent runs; mirrors the web "Review with Claude". No-op
    /// without a cwd. The runner is async and shells out, so we hop off the main
    /// actor and publish the result back on it.
    func runReview(_ id: String) {
        guard let cwd = gitCwd(of: id), !reviewRunning.contains(id) else { return }
        let files = diffBySession[id]?.files ?? []
        let comments = comments(id)
        reviewRunning.insert(id)
        Task {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let result = await JuancodeServices.runReview(
                cwd: cwd, files: files, comments: comments, now: now)
            reviewBySession[id] = result
            reviewRunning.remove(id)
        }
    }

    /// Stage everything and commit, off the main actor. Refreshes the diff + git
    /// state and surfaces a status note on success/failure. Mirrors the web commit
    /// mutation in GitActions.
    func commit(_ id: String, message: String) async {
        guard let cwd = gitCwd(of: id) else { return }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try await commitAll(cwd, msg)
            }.value
            gitNoteBySession[id] = GitNote(ok: true, text: "Committed \(r.sha) · \(r.subject)")
            loadChanges(id)
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
        }
    }

    /// Push the current branch, off the main actor.
    func push(_ id: String) async {
        guard let cwd = gitCwd(of: id) else { return }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try await pushCurrent(cwd)
            }.value
            gitNoteBySession[id] = GitNote(ok: true, text: "Pushed \(r.branch).")
            loadChanges(id)
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
        }
    }

    /// Open a PR for the session's branch (pushes first via gh), off the main actor.
    /// Returns the result for the UI to show the URL, or nil on failure (note set).
    func createPullRequest(_ id: String, title: String, body: String, draft: Bool) async -> PrCreateResult? {
        guard let cwd = gitCwd(of: id) else { return nil }
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try await createPr(cwd, title: title, body: body, draft: draft)
            }.value
            gitNoteBySession[id] = GitNote(
                ok: true, text: r.created ? "Pull request created." : "A PR already exists for this branch.")
            loadChanges(id)
            if let cwd = liveSession(id)?.meta.cwd ?? appState.store.get(id)?.cwd { loadPrs(cwd) }
            return r
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
            return nil
        }
    }

    /// Draft a commit message with Claude for the session's current diff, off the
    /// main actor. Returns the message, or nil on failure (note set).
    func generateCommitMessage(_ id: String) async -> String? {
        guard let cwd = gitCwd(of: id) else { return nil }
        let files = diffBySession[id]?.files ?? []
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await JuancodeServices.generateCommitMessage(cwd, files)
            }.value
        } catch {
            gitNoteBySession[id] = GitNote(ok: false, text: gitErrorText(error))
            return nil
        }
    }

    /// First useful line of any git/gh/commit error, for a clean status note.
    private func gitErrorText(_ error: Error) -> String {
        if let e = error as? GitError { return e.message }
        if let e = error as? GhError { return e.message }
        if let e = error as? CommitMessageError { return e.message }
        return String(describing: error)
    }

    // MARK: - Auth & MCP status (provider + MCP server health) — juancode-daw

    /// Per-provider auth + MCP-server health, loaded in-process via `getAllStatus`
    /// (which shells into the real `claude`/`codex` CLIs). The native analogue of
    /// the web `useQuery(["status"])`. `nil` until first loaded.
    var providerStatus: [ProviderStatus]?
    /// True while a status check is in flight (the CLIs health-check every server,
    /// so this can take a few seconds). Backs the panel's "checking…" affordance.
    var statusLoading = false

    /// Load (or refresh) provider + MCP status off the main actor. Coalesces
    /// concurrent calls. Mirrors `loadPrs`/`loadBeads`. `getAllStatus` never
    /// throws — unavailable providers come back with `available: false`.
    func loadStatus() {
        guard !statusLoading else { return }
        statusLoading = true
        Task {
            let result = await Task.detached(priority: .utility) { await getAllStatus() }.value
            providerStatus = result
            statusLoading = false
        }
    }

    // MARK: - Worktree cleanup (juancode-q6q)

    /// Linked git worktrees discovered across the repos currently in play, grouped
    /// by their repo (project). Each group's `main` worktree is the project root
    /// (kept, not removable); `children` are the linked `juancode/*` worktrees.
    var worktreeGroups: [WorktreeGroup] = []
    var worktreesLoading = false

    /// Scan every distinct session cwd (and any session-owned worktree path) for the
    /// repo's worktrees, grouped per repo and deduped by repo root. Off the main
    /// actor (shells into git).
    func loadWorktrees() {
        guard !worktreesLoading else { return }
        worktreesLoading = true
        let cwds = Set(sessions.map(\.cwd) + sessions.compactMap(\.worktreePath))
        Task {
            // `git worktree list` from any worktree returns the whole repo's set with
            // the main one first, so the main worktree's path is a stable per-repo key.
            var seenRepos = Set<String>()
            var groups: [WorktreeGroup] = []
            for cwd in cwds {
                let trees = await Task.detached(priority: .utility) { await listWorktrees(cwd) }.value
                guard let main = trees.first(where: { $0.main }) else { continue }
                guard seenRepos.insert(main.path).inserted else { continue }
                let children = trees.filter { !$0.main }
                    .sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
                groups.append(WorktreeGroup(main: main, children: children))
            }
            worktreeGroups = groups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            worktreesLoading = false
        }
    }

    /// True if a live session is rooted in `path` — a worktree that's still in use
    /// (removing it would pull the rug from under a running agent).
    func worktreeInUse(_ path: String) -> Bool {
        appState.registry.all().contains { $0.meta.cwd == path || $0.meta.worktreePath == path }
    }

    /// Remove a worktree (and its directory) and refresh the list. Off the main actor.
    func removeWorktreeAt(_ path: String) {
        Task {
            do {
                try await removeWorktree(path)
            } catch {
                errorMessage = "Couldn't remove worktree: \(gitErrorText(error))"
            }
            loadWorktrees()
        }
    }

    /// Linked worktrees that are safe to remove in one sweep: not the main worktree,
    /// not backing a live session, and holding no uncommitted/unpushed work per the
    /// at-risk scan. These are the leftover `juancode/*` trees whose sessions are gone
    /// and whose work is already committed and pushed.
    var safeToRemoveWorktrees: [Worktree] {
        worktreeGroups.flatMap { $0.children }.filter { wt in
            !wt.main
                && !worktreeInUse(wt.path)
                && workAtRiskByPath[WorkAtRiskScan.normalize(wt.path)] == nil
        }
    }

    /// Remove every safe-to-delete worktree in one batched pass, then refresh. The
    /// "clean up" affordance in the worktrees sheet. Skips in-use/at-risk trees by
    /// construction, so nothing with unsaved work or a live session is touched.
    func cleanupSafeWorktrees() {
        let paths = safeToRemoveWorktrees.map(\.path)
        guard !paths.isEmpty else { return }
        Task {
            var failures = 0
            for path in paths {
                do { try await removeWorktree(path) } catch { failures += 1 }
            }
            if failures > 0 {
                errorMessage = "Couldn't remove \(failures) of \(paths.count) worktree(s)."
            }
            loadWorktrees()
        }
    }

    func delete(_ id: String) {
        let meta = appState.store.get(id)
        appState.activityLog.log("close", sessionId: id, project: meta?.cwd ?? "")
        appState.registry.get(id)?.kill()
        appState.store.delete(id)
        activityCancels[id]?(); activityCancels[id] = nil
        gridCancels[id]?(); gridCancels[id] = nil
        metaCancels[id]?(); metaCancels[id] = nil
        stopWatchingChanges(id)
        agentWorktreeBySession.removeValue(forKey: id)
        remoteGridOwners.removeValue(forKey: id)
        if selection == id { selection = nil }
        clearUnread(id)
        refresh()
        if let wt = meta?.worktreePath {
            Task { try? await removeWorktree(wt) }
        }
    }

    /// Force-terminate a session's running agent (SIGTERM then SIGKILL via the
    /// pty) while KEEPING the session record, scrollback, and any worktree so it
    /// can be inspected afterwards — the non-destructive counterpart to
    /// `delete(_:)`/`closeSessions(_:)`. Added for stuck/frozen sessions
    /// (juancode-101), e.g. a dispatched ticket whose prompt never submitted.
    /// No-op if the session isn't live. The process exit drives status → .exited
    /// through the normal `handleExit` path.
    func killSession(_ id: String) {
        guard let session = appState.registry.get(id) else { return }
        session.kill()
        refresh()
    }

    /// Reveal the rolling session activity log in Finder — the JSONL trail of
    /// spawn/seed/activity/exit events (grep by session id to follow one session).
    /// Falls back to the logs folder before the first event has been written.
    func revealActivityLog() {
        appState.activityLog.flush()
        let path = appState.activityLog.logPath
        let target = FileManager.default.fileExists(atPath: path)
            ? path : (path as NSString).deletingLastPathComponent
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    /// Close (kill + delete) every given session in one pass — the per-project
    /// "close all" action. Same teardown as `delete(_:)` but refreshes once and
    /// removes worktrees in a single batched task instead of one per session.
    func closeSessions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var worktrees: [String] = []
        for id in ids {
            let meta = appState.store.get(id)
            if let wt = meta?.worktreePath { worktrees.append(wt) }
            appState.activityLog.log("close", sessionId: id, project: meta?.cwd ?? "")
            appState.registry.get(id)?.kill()
            appState.store.delete(id)
            activityCancels[id]?(); activityCancels[id] = nil
            gridCancels[id]?(); gridCancels[id] = nil
            stopWatchingChanges(id)
            agentWorktreeBySession.removeValue(forKey: id)
            remoteGridOwners.removeValue(forKey: id)
            if selection == id { selection = nil }
            clearUnread(id)
        }
        refresh()
        if !worktrees.isEmpty {
            Task { for wt in worktrees { try? await removeWorktree(wt) } }
        }
    }

    // MARK: - Work at risk (uncommitted/unpushed scanner) — juancode-rxu

    /// Folders holding uncommitted or unpushed work, keyed by normalized path.
    /// Only at-risk entries are held; each scan pass replaces the whole map.
    var workAtRiskByPath: [String: WorkAtRisk] = [:]

    /// Panel-ready list: session-attached folders first, orphaned worktrees last.
    var workAtRiskList: [WorkAtRisk] {
        workAtRiskByPath.values.sorted {
            if $0.orphaned != $1.orphaned { return !$0.orphaned }
            return $0.path.localizedCompare($1.path) == .orderedAscending
        }
    }

    /// The at-risk entry for a session's folder, if any — the sidebar badge lookup.
    func workAtRisk(forSession meta: SessionMeta) -> WorkAtRisk? {
        if let wt = meta.worktreePath,
           let hit = workAtRiskByPath[WorkAtRiskScan.normalize(wt)] { return hit }
        return workAtRiskByPath[WorkAtRiskScan.normalize(meta.cwd)]
    }

    /// A raised "this session's work is about to be forgotten" notice, listed in
    /// the notifications bell until dismissed. One per session at a time.
    struct WorkAtRiskNotice: Identifiable, Equatable, Sendable {
        var id: String { sessionId }
        var sessionId: String
        var title: String
        var path: String
        var createdAt: Int
    }
    var workAtRiskNotices: [WorkAtRiskNotice] = []

    func dismissWorkAtRiskNotice(_ id: String) {
        workAtRiskNotices.removeAll { $0.id == id }
    }

    /// Scan cadence. Coarse — forgotten work is a minutes-scale concern, and each
    /// pass shells `git status` into every distinct session folder and worktree.
    private let workAtRiskInterval: Duration = .seconds(45)
    /// How long a non-busy session must sit silent before its at-risk work nudges.
    private let workAtRiskIdleNudgeMs = 15 * 60_000
    @ObservationIgnored private var workAtRiskLoop: Task<Void, Never>?
    @ObservationIgnored private var workAtRiskScanInFlight = false
    /// Sessions already nudged for the current at-risk episode of their folder;
    /// cleared when the folder comes clean or the session goes busy again, so a
    /// new episode re-alerts (mirrors `dismissedHealth`'s recover-then-fail rule).
    @ObservationIgnored private var workAtRiskNudged: Set<String> = []

    private func startWorkAtRiskLoop() {
        guard workAtRiskLoop == nil else { return }
        workAtRiskLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanWorkAtRiskOnce()
                try? await Task.sleep(for: self?.workAtRiskInterval ?? .seconds(45))
            }
        }
    }

    /// One pass: collect scan roots (session folders + every worktree of the repos
    /// in play, including orphans), probe them off the main actor, publish the
    /// at-risk map, then nudge sessions whose work looks forgotten.
    func scanWorkAtRiskOnce() async {
        guard !workAtRiskScanInFlight else { return }
        workAtRiskScanInFlight = true
        defer { workAtRiskScanInFlight = false }

        let sessionRefs = sessions
            .filter { $0.cwd != OraclePaths.controlDir }
            .map { WorkAtRiskScan.SessionRef(id: $0.id, cwd: $0.cwd, worktreePath: $0.worktreePath) }

        let results = await Task.detached(priority: .utility) { () -> [String: WorkAtRisk] in
            // One worktree listing per repo: `git worktree list` from any worktree
            // returns the whole set with the main one first (stable per-repo key).
            var worktreesByRepo: [String: [Worktree]] = [:]
            for cwd in Set(sessionRefs.map(\.cwd) + sessionRefs.compactMap(\.worktreePath)) {
                let trees = await listWorktrees(cwd)
                guard let main = trees.first(where: { $0.main }) else { continue }
                if worktreesByRepo[main.path] == nil { worktreesByRepo[main.path] = trees }
            }
            let roots = WorkAtRiskScan.collectRoots(sessions: sessionRefs,
                                                    worktreesByRepo: worktreesByRepo)
            // Probe with bounded concurrency — a wide scan shouldn't fork a git
            // process per folder all at once.
            var out: [String: WorkAtRisk] = [:]
            await withTaskGroup(of: WorkAtRisk?.self) { group in
                var next = 0
                func enqueue() {
                    guard next < roots.count else { return }
                    let root = roots[next]; next += 1
                    group.addTask {
                        guard let probed = await probeWorkAtRisk(root.path) else { return nil }
                        return WorkAtRiskScan.classify(root, state: probed.state,
                                                       dirtyFiles: probed.dirtyFiles,
                                                       aheadOfBase: probed.aheadOfBase)
                    }
                }
                for _ in 0..<4 { enqueue() }
                while let risk = await group.next() {
                    if let risk { out[risk.path] = risk }
                    enqueue()
                }
            }
            return out
        }.value

        workAtRiskByPath = results

        // Episode reset: forget a nudge once the session's folder is clean again,
        // the session went back to work, or the session is gone.
        workAtRiskNudged = workAtRiskNudged.filter { id in
            guard let meta = sessions.first(where: { $0.id == id }) else { return false }
            return workAtRisk(forSession: meta) != nil && activity(id) != .busy
        }

        // Nudge pass. Read live last-output straight from the registry — the
        // published `sessions` snapshot's `updatedAt` can lag (see health loop).
        let liveMeta = Dictionary(appState.registry.all().map { ($0.id, $0.meta) },
                                  uniquingKeysWith: { a, _ in a })
        let metasById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inputs: [WorkAtRiskScan.NudgeInput] = sessions
            .filter { $0.cwd != OraclePaths.controlDir }
            .map { meta in
                WorkAtRiskScan.NudgeInput(
                    id: meta.id, atRisk: workAtRisk(forSession: meta) != nil,
                    status: meta.status, isLive: liveMeta[meta.id] != nil,
                    activity: activity(meta.id),
                    lastOutputMs: liveMeta[meta.id]?.updatedAt ?? meta.updatedAt)
            }
        let due = WorkAtRiskScan.nudges(inputs, nowMs: nowMs(),
                                        idleMs: workAtRiskIdleNudgeMs,
                                        alreadyNudged: workAtRiskNudged)
        guard !due.isEmpty else { return }
        // All due sessions are spent for this episode, but raise only one notice
        // per folder (several exited sessions often share a dirty cwd — one launch
        // shouldn't stack N identical alerts), fronted by the freshest session.
        workAtRiskNudged.formUnion(due)
        var noticedPaths = Set(workAtRiskNotices.map(\.path))
        let dueMetas = due.compactMap { metasById[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        var raised = false
        for meta in dueMetas {
            guard let risk = workAtRisk(forSession: meta),
                  noticedPaths.insert(risk.path).inserted else { continue }
            workAtRiskNotices.removeAll { $0.sessionId == meta.id }
            workAtRiskNotices.append(WorkAtRiskNotice(
                sessionId: meta.id, title: meta.title, path: risk.path, createdAt: nowMs()))
            postNotificationWebhook(event: .workAtRisk, title: meta.title,
                                    sessionId: meta.id, cwd: risk.path)
            raised = true
        }
        if raised { NSApp.requestUserAttention(.informationalRequest) }
    }
}

/// Outcome of loading a diff for a ChangesPanel source — the files, the resolved
/// base ref (for `.base`), and a user-facing error if the fetch failed.
private struct LoadedDiff: Sendable {
    var diff: DiffResult?
    var base: String?
    var error: String?
}

/// Resolve a `ChangesSource` to its diff off the main actor (juancode-49w). The
/// working-tree path keeps the old "swallow errors, keep prior diff" behaviour;
/// the base/PR paths surface a clean error string the panel can show.
private func loadDiffForSource(_ cwd: String, _ source: AppModel.ChangesSource) async -> LoadedDiff {
    switch source {
    case .workingTree:
        return LoadedDiff(diff: try? await getDiff(cwd), base: nil, error: nil)
    case .base:
        do {
            let bd = try await getBaseDiff(cwd)
            return LoadedDiff(diff: bd.result, base: bd.base, error: nil)
        } catch {
            return LoadedDiff(diff: nil, base: nil, error: diffErrorMessage(error))
        }
    case .pr(let pr):
        do {
            return LoadedDiff(diff: try await getPrDiff(cwd, number: pr.number), base: nil, error: nil)
        } catch {
            return LoadedDiff(diff: nil, base: nil, error: diffErrorMessage(error))
        }
    case .commit(let sha, _):
        do {
            return LoadedDiff(diff: try await getCommitDiff(cwd, sha: sha), base: nil, error: nil)
        } catch {
            return LoadedDiff(diff: nil, base: nil, error: diffErrorMessage(error))
        }
    }
}

/// The clean message from a GitError/GhError, else a generic description.
private func diffErrorMessage(_ error: Error) -> String {
    if let e = error as? GitError { return e.message }
    if let e = error as? GhError { return e.message }
    return String(describing: error)
}
