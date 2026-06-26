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
    /// Whatever went wrong during bootstrap, surfaced in the dock.
    var setupError: String?
    /// Whether the dock is expanded (vs. the collapsed floating button).
    var expanded = false
    /// Which dock tab is showing.
    var tab: OracleTab = .issues
    /// The global bd tracker listing (control-dir cwd), loaded lazily + refreshable.
    var globalBeads: BeadsResult?
    /// The pinned Oracle agent session id, once created/restored.
    var oracleSessionId: String?

    /// Bumped to ask the chat terminal to grab keyboard focus (⌃Space). The chat
    /// view watches this and makes the terminal first responder on each change.
    var chatFocusToken = 0

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

    /// The live Oracle agent session, if running.
    var session: Session? { oracleSessionId.flatMap { app.liveSession($0) } }

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
        app.focusTerminal()
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

    /// Bring the Oracle agent back up from the chat tab's "Start Oracle" button.
    /// `bootstrap()` is a one-shot (its guard no-ops once `ready`/`loop` are set),
    /// so once the agent session exits the chat needs its own re-entry point.
    func startAgent() {
        guard ready else { bootstrap(); return }
        ensureAgentSession()
    }

    /// Restart the Oracle agent from the chat tab: kill the live session and spawn a
    /// fresh one. The chat transcript is disposable — Oracle's durable state lives in
    /// its bd tracker + files (see `ensureAgentSession`) — so a clean respawn is safe
    /// when the CLI's TUI gets garbled or the conversation is stuck.
    func restartAgent() {
        guard ready else { startAgent(); return }
        if let id = oracleSessionId { app.delete(id) }
        oracleSessionId = nil
        ensureAgentSession()
    }

    /// Restore the most recent persisted Oracle session (reactivating it) or spawn
    /// a fresh one. The agent's role lives in the control dir's `AGENTS.md` (read by
    /// the CLI on launch), so the fresh spawn needs no seed prompt. The Oracle session
    /// is identified by
    /// its unique cwd (the control dir), so there's no schema/protocol change.
    private func ensureAgentSession() {
        if let existing = app.liveSession(inCwd: controlDir) {
            oracleSessionId = existing.id
            return
        }
        // Don't resume a prior Oracle conversation — its CLI session may be gone
        // (claude/codex print "No conversation found …" and exit, leaving a dead
        // session). Oracle's durable state lives in its bd tracker + files, not the
        // chat, so we always start fresh and clear out the stale exited sessions.
        for meta in app.persistedSessions(inCwd: controlDir) { app.delete(meta.id) }
        spawnAgent()
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
    func dispatch(project: String, prompt: String, provider: ProviderId = .claude, worktree: Bool = false) {
        let req = OracleDispatch(project: project, prompt: prompt,
                                 provider: provider.rawValue, worktree: worktree)
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
                             initialInput: d.prompt, select: true)
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
