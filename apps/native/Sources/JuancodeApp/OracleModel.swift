import Foundation
import Combine
import JuancodeCore
import JuancodeServices

/// Drives the global "Oracle" helper (juancode-wjg): bootstraps the control dir,
/// owns the pinned Oracle agent session, keeps `state.json` fresh, tails the
/// dispatch mailbox to spawn agents into projects, and exposes the global bd
/// tracker to the dock UI.
///
/// It sits alongside `AppModel` (held by the app, injected as a second
/// `EnvironmentObject`) and leans on it for the real work: session creation,
/// worktree isolation, and the live registry are all `AppModel`'s.
@MainActor
final class OracleModel: ObservableObject {
    private let app: AppModel

    /// True once the control dir is bootstrapped and the agent session is up.
    @Published var ready = false
    /// Whatever went wrong during bootstrap, surfaced in the dock.
    @Published var setupError: String?
    /// Whether the dock is expanded (vs. the collapsed floating button).
    @Published var expanded = false
    /// Which dock tab is showing.
    @Published var tab: OracleTab = .issues
    /// The global bd tracker listing (control-dir cwd), loaded lazily + refreshable.
    @Published var globalBeads: BeadsResult?
    /// The pinned Oracle agent session id, once created/restored.
    @Published var oracleSessionId: String?

    /// Byte offset into `dispatch.jsonl` we've consumed up to. Initialized to the
    /// file's end at bootstrap so we only act on dispatches made this run.
    private var dispatchOffset = 0
    private var loop: Task<Void, Never>?
    private var beadsLoading = false
    /// Last snapshot written to `state.json`, to skip rewriting an unchanged file
    /// every tick (the timestamp is excluded from the comparison).
    private var lastState: OracleState?

    enum OracleTab: String, CaseIterable { case issues = "Issues", chat = "Chat" }

    /// The Oracle agent's working directory (its control dir). Sessions in this cwd
    /// are Oracle's own and are hidden from the per-project sidebar.
    var controlDir: String { OraclePaths.controlDir }

    /// The live Oracle agent session, if running.
    var session: Session? { oracleSessionId.flatMap { app.liveSession($0) } }

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
        ready = true
        startLoop()
        Task {
            // Stand up the bd tracker, then load it and bring the agent up. The
            // agent's cwd already exists (prep above), so it can start in parallel.
            await ensureOracleTracker()
            ensureAgentSession()
            loadGlobalBeads()
        }
    }

    /// Restore the most recent persisted Oracle session (reactivating it) or spawn
    /// a fresh one seeded with the role prompt. The Oracle session is identified by
    /// its unique cwd (the control dir), so there's no schema/protocol change.
    private func ensureAgentSession() {
        if let existing = app.liveSession(inCwd: controlDir) {
            oracleSessionId = existing.id
            return
        }
        if let persisted = app.mostRecentPersisted(cwd: controlDir) {
            oracleSessionId = persisted.id
            Task {
                await app.reactivate(persisted.id)
                if !app.isLive(persisted.id) { spawnAgent() }
            }
            return
        }
        spawnAgent()
    }

    private func spawnAgent() {
        Task {
            // Accept-all so Oracle can run bd + manage its mailbox without prompts;
            // it operates only in its own control dir. Don't steal the selection.
            let s = await app.create(provider: .claude, cwd: controlDir, skipPermissions: true,
                                     isolateWorktree: false, initialInput: oracleSeedPrompt, select: false)
            oracleSessionId = s?.id
        }
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
            s.write("\(text)\r")
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

    /// One pass: publish the live state snapshot and process any new dispatch lines.
    private func tick() async {
        writeState()
        let (dispatches, newOffset) = readOracleDispatches(since: dispatchOffset)
        dispatchOffset = newOffset
        for d in dispatches {
            // Spawn (or seed) the agent in the target project. Selecting it lets the
            // user jump straight to freshly dispatched work.
            await app.create(provider: d.resolvedProvider, cwd: d.project,
                             skipPermissions: false, isolateWorktree: d.worktree ?? false,
                             initialInput: d.prompt, select: true)
        }
    }

    /// Write the current session/workdir snapshot for the agent to read.
    private func writeState() {
        let snaps = app.sessions.map { meta in
            OracleSessionSnapshot(
                id: meta.id, title: meta.title, cwd: meta.cwd,
                provider: meta.provider.rawValue, status: meta.status.rawValue,
                activity: app.activity(meta.id)?.rawValue, live: app.isLive(meta.id))
        }
        let next = OracleState(updatedAt: nowMs(), workdirs: knownProjects, sessions: snaps)
        // Skip the write when nothing meaningful changed (ignore the timestamp).
        if let last = lastState, last.workdirs == next.workdirs, last.sessions == next.sessions { return }
        lastState = next
        try? writeOracleState(next)
    }
}
