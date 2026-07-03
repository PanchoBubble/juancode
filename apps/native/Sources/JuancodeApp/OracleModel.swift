import Foundation
import Observation
import AppKit
import JuancodeCore
import JuancodeServices

/// UserDefaults keys for the dock's last real Ghostty-measured grid (see `dockGrid`).
private let dockGridColsKey = "oracle.grid.cols"
private let dockGridRowsKey = "oracle.grid.rows"

/// Drives the global "Oracle" helper (juancode-wjg): bootstraps the control dir,
/// owns the pinned Oracle agent session, keeps `state.json` fresh, tails the
/// dispatch mailbox to spawn agents into projects, and exposes the global bd
/// tracker to the dock UI.
///
/// It sits alongside `AppModel` (held by the app, injected as a second
/// `EnvironmentObject`) and leans on it for the real work: session creation,
/// worktree isolation, and the live registry are all `AppModel`'s.
@MainActor
@Observable
final class OracleModel {
    private let app: AppModel

    /// True once the control dir is bootstrapped and the agent session is up.
    var ready = false
    /// Whether we've already auto-presented the chat at launch (juancode-8n0). A
    /// one-shot so re-entrant `bootstrap()` calls don't keep re-opening the dock after
    /// the user has closed it.
    @ObservationIgnored private var didAutoPresentChat = false
    /// Whatever went wrong during bootstrap, surfaced in the dock.
    var setupError: String?
    /// Whether the dock is expanded (vs. the collapsed floating button). Mirrored onto
    /// `AppModel` so it can treat the open dock as the viewer for Oracle's own
    /// (sidebar-hidden) sessions and clear/suppress their unread notifications.
    var expanded = false {
        didSet { app.oracleDockExpanded = expanded }
    }
    /// Which dock tab is showing. Defaults to `.chat` so the Oracle conversation is
    /// the surface the app leads with (juancode-8n0) — chat is the primary window,
    /// not a transient afterthought.
    var tab: OracleTab = .chat
    /// The global bd tracker listing (control-dir cwd), loaded lazily + refreshable.
    var globalBeads: BeadsResult?
    /// The Oracle agent session currently shown in the chat. You can run several
    /// Oracles in parallel (all live in the control dir); this points at the active
    /// one and the session rail lists them all (see `oracleSessions`).
    var oracleSessionId: String?

    /// Bumped to ask the chat terminal to grab keyboard focus (⌃Space). The chat
    /// view watches this and makes the terminal first responder on each change.
    var chatFocusToken = 0

    /// Bumped to hard-refresh the chat terminal: folded into the terminal view's
    /// `.id`, so a change rebuilds it and replays the full scrollback — the fix for a
    /// corrupted/garbled Oracle render, short of a full `restartAgent()`.
    var chatRefreshToken = 0

    /// Byte offset into `dispatch.jsonl` we've consumed up to. Initialized to the
    /// file's end at bootstrap so we only act on dispatches made this run.
    @ObservationIgnored private var dispatchOffset = 0
    /// Byte offset into `ask.jsonl` we've consumed up to. Primed to the file's end at
    /// bootstrap so we only act on asks made this run (mirrors `dispatchOffset`).
    @ObservationIgnored private var askOffset = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var beadsLoading = false
    /// Last snapshot written to `state.json`, to skip rewriting an unchanged file
    /// every tick (the timestamp is excluded from the comparison).
    private var lastState: OracleState?

    enum OracleTab: String, CaseIterable { case issues = "Issues", chat = "Chat" }

    /// The Oracle agent's working directory (its control dir). Sessions in this cwd
    /// are Oracle's own and are hidden from the per-project sidebar.
    var controlDir: String { OraclePaths.controlDir }

    /// The live Oracle agent session currently shown in the chat, if running.
    var session: Session? { oracleSessionId.flatMap { app.liveSession($0) } }

    /// Every Oracle agent session — they all live in the control dir — most-recent
    /// first. Drives the dock's session rail so you can switch between (and spin up)
    /// parallel Oracles. Excludes archived ones.
    var oracleSessions: [SessionMeta] {
        app.sessions
            .filter { $0.cwd == controlDir && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Count of open global tracker items, for the top-bar Issues badge.
    var openCount: Int {
        guard let r = globalBeads, r.available else { return 0 }
        return r.issues.filter { $0.status != "closed" }.count
    }

    /// Open the Oracle panel on a specific tab (from the top command bar / shortcuts).
    /// The agent CLI is spawned here — on open, when the drawer's size is known — not
    /// at launch, so it boots into the panel's grid rather than the main window's.
    func open(tab: OracleTab) {
        // Act as a toggle: invoking the command for the tab that's already showing
        // collapses the dock, so the top-bar Issues / Oracle buttons (and ⌘⇧I) close
        // it as well as open it — otherwise the panel only ever opens and feels stuck.
        if expanded, self.tab == tab {
            collapse()
            return
        }
        self.tab = tab
        expanded = true
        bootstrap()
        ensureAgentSession()
        if tab == .issues { loadGlobalBeads() }
        // Opening straight onto the chat should land the cursor in the agent's input
        // (same as ⌃Space), so the focus handoff into Oracle is deterministic.
        if tab == .chat { chatFocusToken += 1 }
    }

    /// Toggle the panel (⌃Space). Bootstraps + brings the agent up on open; on close
    /// hands focus back to the open session's terminal.
    func toggle() {
        if expanded { collapse(); return }
        expanded = true
        bootstrap()
        ensureAgentSession()
    }

    /// ⌃Space: open the Oracle on the chat tab with the input focused, so you can
    /// start typing to Oracle immediately. Toggles closed when the chat is already
    /// showing. Brings the agent up if it isn't running.
    func toggleChatFocused() {
        if expanded && tab == .chat {
            collapse()
            return
        }
        expanded = true
        tab = .chat
        bootstrap()
        ensureAgentSession()
        chatFocusToken += 1
    }

    /// Collapse the dock and hand keyboard focus straight back to the currently-open
    /// session's terminal, so you can keep typing without a manual click (juancode-cwa).
    /// Every close path routes through here to keep the focus handoff deterministic
    /// rather than leaving focus stranded on the dismissed panel.
    func collapse() {
        guard expanded else { return }
        expanded = false
        // Hand focus back to the session terminal — but not when an editor overlay is
        // open beneath the dock (the dock now layers above it): the editor pty should
        // keep focus so you land back in it, not the main terminal behind it.
        if app.editing == nil { app.focusTerminal() }
    }

    init(app: AppModel) { self.app = app }

    deinit { loop?.cancel() }

    /// One-time setup: create the control dir + tracker, restore-or-spawn the agent
    /// session, prime the dispatch offset, and start the tail/state loop. Safe to
    /// call once on launch; no-ops if already ready.
    func bootstrap() {
        guard !ready, setupError == nil, loop == nil else { return }
        // Fast, subprocess-free prep so the dock is usable immediately — the slow
        // tracker setup (git init / bd init) runs in the background below.
        do {
            try prepareOracleControlDir()
        } catch {
            setupError = (error as? OracleError)?.message ?? error.localizedDescription
            return
        }
        // Only act on dispatches appended after this point — pre-existing lines
        // belong to a previous run and have already been handled.
        dispatchOffset = (try? Data(contentsOf: URL(fileURLWithPath: OraclePaths.dispatchFile)).count) ?? 0
        askOffset = (try? Data(contentsOf: URL(fileURLWithPath: OraclePaths.askFile)).count) ?? 0
        ready = true
        startLoop()
        Task {
            // Stand up the bd tracker and load the global issue listing. The agent
            // itself is NOT spawned here — it comes up lazily when the panel is first
            // opened (open()/toggle()), so it boots sized to the drawer rather than at
            // launch when the drawer's size isn't known yet.
            await ensureOracleTracker()
            loadGlobalBeads()
        }
    }

    /// Present the Oracle chat as the app's main surface on launch (juancode-8n0):
    /// bootstrap, then open the dock on the chat tab with the agent up and the input
    /// focused — so the app opens *into* the conversation rather than to an empty
    /// session pane you have to toggle Oracle open over. A one-shot (`didAutoPresentChat`)
    /// so it only fires for the first appearance, never re-opening the dock after the
    /// user has deliberately closed it. To revert "chat as main window", drop this call
    /// from the dock's `.onAppear` (and reset the default `tab` to `.issues`).
    func presentChatAtLaunch() {
        bootstrap()
        guard !didAutoPresentChat else { return }
        didAutoPresentChat = true
        tab = .chat
        expanded = true
        ensureAgentSession()
        chatFocusToken += 1
    }

    /// Bring the Oracle agent back up from the chat tab's "Start Oracle" button.
    /// `bootstrap()` is a one-shot (its guard no-ops once `ready`/`loop` are set),
    /// so once the agent session exits the chat needs its own re-entry point.
    func startAgent() {
        guard ready else { bootstrap(); return }
        ensureAgentSession()
    }

    /// Restart the Oracle agent from the chat tab: spawn a fresh Oracle when the current
    /// CLI's TUI gets garbled or the conversation is stuck. The old session is left in
    /// the rail (not deleted) so it stays available to continue later — its durable state
    /// lives in Oracle's bd tracker + files. Only the active chat is repointed; other
    /// live Oracles are untouched.
    func restartAgent() {
        guard ready else { startAgent(); return }
        // Stop the garbled pty but keep its persisted row, so the conversation stays
        // in the rail and can be resumed later (kill ≠ delete).
        if let id = oracleSessionId { app.liveSession(id)?.kill() }
        oracleSessionId = nil
        spawnAgent()
    }

    /// Hard-refresh the chat terminal without touching the live CLI: rebuild the view
    /// so it replays the full scrollback and repaints cleanly. Try this before
    /// `restartAgent()` when only the render is corrupted, not the conversation.
    func refreshChat() {
        chatRefreshToken &+= 1
    }

    /// Spin up an additional Oracle agent and make it the active chat. Several Oracles
    /// can run in parallel — all in the control dir, all listed in the session rail —
    /// so you can keep one working while you start another. Always a fresh spawn (it
    /// becomes `oracleSessionId` once up); existing Oracles are untouched.
    func newOracle() {
        guard ready else { bootstrap(); return }
        tab = .chat
        spawnAgent()
        chatFocusToken += 1
    }

    /// Switch the chat to an existing Oracle session (rail tap). No-op if it's already
    /// active; focuses the chat input on switch. If the tapped Oracle has exited, revive
    /// it (resume its CLI conversation via the pinned session id) so a past session can
    /// be continued, not just viewed.
    func selectOracle(_ id: String) {
        guard oracleSessionId != id else { return }
        oracleSessionId = id
        tab = .chat
        chatFocusToken += 1
        if app.liveSession(id) == nil {
            // Resume into the dock's grid, not the wide main-window one, so the CLI
            // boots at the drawer width instead of wrapping into garbage.
            Task { await app.reactivate(id, grid: dockGrid) }
        }
    }

    /// Permanently delete an Oracle session (rail right-click → Delete): kill its pty,
    /// drop its persisted row + scrollback, and remove any auto-created worktree — the
    /// same full teardown the per-project sidebar's Delete does (`app.delete`). Unlike
    /// `restartAgent` (kill ≠ delete, keeps it in the rail to resume), this discards the
    /// conversation for good. If the deleted Oracle was the active chat, repoint to the
    /// next-most-recent Oracle *before* tearing it down so the chat never renders a dead
    /// session; with none left, the chat falls back to its "Start Oracle" affordance.
    func deleteOracle(_ id: String) {
        if oracleSessionId == id {
            oracleSessionId = oracleSessions.first { $0.id != id }?.id
        }
        app.delete(id)
    }

    /// Make sure the chat is pointed at a live Oracle: keep the active one if it's
    /// still running, else adopt the most recent live Oracle, else continue the most
    /// recent *past* Oracle (resumed via its pinned CLI session id), and only spawn a
    /// fresh one when there are genuinely no past Oracles to revive. Past sessions are
    /// kept — not deleted — so you can see and continue earlier Oracle conversations
    /// (juancode: persist Oracle sessions), matching the per-project session list.
    private func ensureAgentSession() {
        if let id = oracleSessionId, app.liveSession(id) != nil { return }
        if let existing = app.liveSession(inCwd: controlDir) {
            oracleSessionId = existing.id
            return
        }
        // No live Oracle. Rather than discard history, continue the most recent past
        // Oracle; if its CLI conversation can't be resumed, fall back to a fresh spawn.
        if let recent = oracleSessions.first {
            Task {
                // Point the chat at it up front so the resumed pty is visible while it
                // boots; resume into the dock grid (not the wide main-window grid) so
                // the CLI doesn't wrap into garbage inside the drawer.
                oracleSessionId = recent.id
                let resumed = await app.reactivate(recent.id, grid: dockGrid)
                if !resumed {
                    // Couldn't revive its prior conversation (stale/absent CLI session) —
                    // start fresh and clear the resume error so the dock doesn't show a
                    // stale "no conversation to resume" banner.
                    app.errorMessage = nil
                    spawnAgent()
                }
            }
        } else {
            spawnAgent()
        }
    }

    /// Spawn the Oracle agent. By default it boots **silent** — its role and startup
    /// routine live in the control dir's `AGENTS.md`, which the CLI reads on launch, so
    /// there's no seed prompt typed into the chat. `seed` is only non-empty on the ask
    /// path (`receiveAsk`), where the remote question is delivered as the first turn.
    private func spawnAgent(seed: String = "") {
        Task {
            // Accept-all so Oracle can run bd + manage its mailbox without prompts;
            // it operates only in its own control dir. Don't steal the selection.
            // Spawn sized to the Oracle drawer (not the main window) so the agent CLI's
            // alt-screen boots at the drawer's width — otherwise it renders at the wide
            // main-window size and wraps into garbage inside the narrower drawer.
            let grid = dockGrid
            let s = await app.create(provider: .claude, cwd: controlDir, skipPermissions: true,
                                     isolateWorktree: false, initialInput: seed,
                                     select: false, cols: grid.cols, rows: grid.rows)
            oracleSessionId = s?.id
        }
    }

    /// Deliver a remote ask (drained from `ask.jsonl`, appended by the MCP sidecar)
    /// to the Oracle agent. Writes into the live session if one is up; otherwise
    /// spawns the agent seeded with the ask text so the question isn't lost. Surfaces
    /// the chat so the exchange is visible on the Mac.
    func receiveAsk(_ text: String) {
        expanded = true
        tab = .chat
        if let s = session {
            // Route through `submit` (bracketed paste + separate Enter), not a raw
            // `"\(text)\r"` burst — the latter makes the CLI read a multi-line ask
            // as a paste and keep the CR as a literal newline, leaving it unsent.
            s.submit(text)
        } else {
            spawnAgent(seed: text)
        }
    }

    /// Persist the real grid the Ghostty surface measured for the dock, so the next
    /// agent spawn boots at exactly that size — no reflow, no garbled startup banner.
    /// The CLI emits its (normal-screen) startup output at the spawn grid; if that
    /// mismatches the render grid it wraps wrong and lands mis-wrapped in scrollback.
    func rememberDockGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        UserDefaults.standard.set(cols, forKey: dockGridColsKey)
        UserDefaults.standard.set(rows, forKey: dockGridRowsKey)
    }

    /// The grid the agent CLI boots into. Prefer the real grid Ghostty last measured
    /// for the dock (persisted via `rememberDockGrid`); fall back to an estimate from
    /// the drawer width + window height only before the surface has ever measured one.
    /// Cell metrics (~9.85×18pt) are SwiftTerm's defaults — a rough seed for the very
    /// first spawn; the live Ghostty view then measures the true grid and remembers it.
    private var dockGrid: (cols: Int, rows: Int) {
        let storedCols = UserDefaults.standard.integer(forKey: dockGridColsKey)
        let storedRows = UserDefaults.standard.integer(forKey: dockGridRowsKey)
        if storedCols > 0, storedRows > 0 { return (storedCols, storedRows) }
        let w = max(460, (UserDefaults.standard.object(forKey: "oracle.panel.width") as? Double) ?? 600)
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        let winH = Double(window?.contentView?.bounds.height ?? 820)
        let cols = max(40, Int((w - 20) / 9.85))
        let rows = max(14, Int((winH - 92) / 18.0))
        return (cols, rows)
    }

    /// Refresh the global bd tracker listing (control-dir cwd). Coalesces calls.
    func loadGlobalBeads() {
        guard !beadsLoading else { return }
        beadsLoading = true
        let cwd = controlDir
        Task {
            let result = await Task.detached(priority: .utility) { await getBeads(cwd) }.value
            globalBeads = result
            beadsLoading = false
        }
    }

    /// Dispatch an agent into a project. Routed through the same mailbox the agent
    /// uses, so UI- and agent-initiated dispatch share one code path; the tail loop
    /// turns it into a real session.
    func dispatch(project: String, prompt: String, provider: ProviderId = .claude,
                  worktree: Bool = false, model: String? = nil) {
        let req = OracleDispatch(project: project, prompt: prompt,
                                 provider: provider.rawValue, worktree: worktree, model: model)
        try? appendOracleDispatch(req)
    }

    /// Send a global issue's context into the Oracle chat for it to reason about,
    /// rather than dispatching it directly. Starts the agent if needed.
    func ask(_ text: String) {
        expanded = true
        tab = .chat
        if let s = session {
            s.submit(text) // bracketed paste + separate Enter (see `receiveAsk`)
        } else {
            ensureAgentSession()
        }
    }

    /// Distinct project work dirs currently in play (for the dispatch picker),
    /// excluding the Oracle control dir itself.
    var knownProjects: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in app.sessions where s.cwd != controlDir {
            if seen.insert(s.cwd).inserted { out.append(s.cwd) }
        }
        return out.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    // MARK: - Tail + state loop

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// One pass: publish the live state snapshot and process any new dispatch + ask lines.
    private func tick() async {
        writeState()
        let (dispatches, newOffset) = readOracleDispatches(since: dispatchOffset)
        dispatchOffset = newOffset
        for d in dispatches {
            // Guard the target path: a dispatch to a non-existent dir would otherwise
            // silently spawn a session in the wrong place. Reject it and tell Oracle
            // so it can re-dispatch to a real `projects` entry rather than guessing.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.project, isDirectory: &isDir), isDir.boolValue else {
                rejectDispatch(d)
                continue
            }
            // Spawn (or seed) the agent in the target project. Selecting it lets the
            // user jump straight to freshly dispatched work.
            await app.create(provider: d.resolvedProvider, cwd: d.project,
                             skipPermissions: true, isolateWorktree: d.worktree ?? false,
                             initialInput: d.prompt, select: true, model: d.model)
        }
        // Drain the ask mailbox (remote/MCP path) into the live Oracle session.
        let (asks, newAskOffset) = readOracleAsks(since: askOffset)
        askOffset = newAskOffset
        for a in asks { receiveAsk(a.text) }
    }

    /// Write the current session/workdir snapshot for the agent to read.
    private func writeState() {
        let snaps = app.sessions.map { meta in
            OracleSessionSnapshot(
                id: meta.id, title: meta.title, cwd: meta.cwd,
                provider: meta.provider.rawValue, status: meta.status.rawValue,
                activity: app.activity(meta.id)?.rawValue, live: app.isLive(meta.id))
        }
        let projects = discoverOracleProjects(
            workspaceRoot: Config.workspaceRoot,
            sessionCwds: app.sessions.compactMap { $0.cwd == controlDir ? nil : $0.cwd })
        let next = OracleState(updatedAt: nowMs(), workdirs: knownProjects, sessions: snaps, projects: projects)
        // Skip the write when nothing meaningful changed (ignore the timestamp).
        if let last = lastState, last.workdirs == next.workdirs, last.sessions == next.sessions,
           last.projects == next.projects { return }
        lastState = next
        try? writeOracleState(next)
    }

    /// Tell the Oracle agent a dispatch was rejected (bad `project` path) so it can
    /// correct itself instead of silently losing the work. Delivered into its live
    /// chat the same way a remote ask is; no-op if the agent isn't up (the agent
    /// re-reads `state.json` on its next turn anyway).
    private func rejectDispatch(_ d: OracleDispatch) {
        guard let s = session else { return }
        s.submit("⚠️ Dispatch rejected: \"\(d.project)\" is not an existing directory. "
            + "Use the exact `path` of an entry in state.json's `projects` list — don't guess paths.")
    }
}
