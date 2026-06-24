import Foundation
import Combine
import JuancodeCore
import JuancodeServices
import JuancodePersistence
import JuancodeServer

/// Observable view-model bridging the SwiftUI shell to the shared `AppState`. The
/// local UI is an in-process subscriber to the same `SessionRegistry` the
/// embedded server drives — there is no WS hop for the local view.
@MainActor
final class AppModel: ObservableObject {
    let appState: AppState

    @Published var sessions: [SessionMeta] = []
    @Published var activities: [String: SessionActivity] = [:]
    @Published var selection: String?
    @Published var showingNewSession = false
    @Published var errorMessage: String?
    /// Sessions whose accept-all flag is mid-flip (pty being resume-restarted), so
    /// the UI can disable the control until the new pty is up.
    @Published var flippingPermissions: Set<String> = []

    /// Open-PR lists per folder cwd, loaded lazily by `FolderHeader` and refreshed
    /// in the background. Mirrors the web's per-folder `useQuery(["prs", cwd])`.
    @Published var prsByCwd: [String: PrListResult] = [:]
    /// cwds with a PR fetch in flight, so a refresh doesn't stampede.
    private var prsLoading: Set<String> = []

    private var activityCancels: [String: () -> Void] = [:]

    init(appState: AppState) {
        self.appState = appState
        appState.registry.onCreate { [weak self] s in
            Task { @MainActor in self?.watch(s); self?.refresh() }
        }
        for s in appState.registry.all() { watch(s) }
        refresh()
    }

    /// Persisted sessions (incl. exited), with live registry meta preferred for
    /// running ones so status/title/usage reflect the live pty.
    func refresh() {
        let persisted = appState.store.list()
        let live = Dictionary(appState.registry.all().map { ($0.id, $0.meta) }, uniquingKeysWith: { a, _ in a })
        sessions = persisted.map { live[$0.id] ?? $0 }
    }

    func activity(_ id: String) -> SessionActivity? { activities[id] }

    func isLive(_ id: String) -> Bool { appState.registry.get(id) != nil }

    func liveSession(_ id: String) -> Session? { appState.registry.get(id) }

    func scrollback(_ id: String) -> [UInt8] {
        appState.registry.get(id)?.getScrollback() ?? appState.store.getScrollback(id) ?? []
    }

    private func watch(_ s: Session) {
        activities[s.id] = s.activity
        activityCancels[s.id]?()
        activityCancels[s.id] = s.onActivity { [weak self] st, _ in
            Task { @MainActor in self?.activities[s.id] = st }
        }
        s.onExit { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    @discardableResult
    func create(provider: ProviderId, cwd: String, skipPermissions: Bool,
                isolateWorktree: Bool, initialInput: String? = nil) async -> Session? {
        do {
            var workCwd = cwd
            var worktreePath: String? = nil
            if isolateWorktree {
                let wt = try await createWorktree(cwd, String(UUID().uuidString.prefix(8)).lowercased())
                workCwd = wt.path
                worktreePath = wt.path
            }
            // Spawn off the main actor: this resolves the CLI via a login shell and
            // forkpty()s — work that must never block the UI run loop.
            let state = appState
            let cwdToUse = workCwd
            let wt = worktreePath
            let s = try await Task.detached(priority: .userInitiated) {
                try state.registry.create(
                    provider: provider, cwd: cwdToUse, cols: 80, rows: 24,
                    opts: SpawnOptions(skipPermissions: skipPermissions), worktreePath: wt)
            }.value
            // Seed the session with an initial prompt once its TUI is up — the same
            // mechanism the WS `.create` path uses (Session.autoSubmit).
            if let initialInput, !initialInput.isEmpty { s.autoSubmit(initialInput) }
            refresh()
            selection = s.id
            return s
        } catch {
            errorMessage = "Failed to start \(provider.rawValue): \(error)"
            return nil
        }
    }

    /// Start a new session directly in a given folder + provider, bypassing the
    /// NewSessionView sheet. Mirrors the web sidebar's per-folder "+" agent menu
    /// (accept-all off, no worktree). Selects the new session on success.
    func createInFolder(provider: ProviderId, cwd: String) {
        Task { await create(provider: provider, cwd: cwd, skipPermissions: false, isolateWorktree: false) }
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

    /// Spawn a Claude session in the PR's folder seeded with a prompt that asks the
    /// agent to review the PR and its diff — mirrors the web "Work on" action.
    /// Always uses the folder's cwd (not a worktree) so the branch context lines up.
    func workOnPr(_ pr: PullRequest, cwd: String) {
        Task {
            await create(provider: .claude, cwd: cwd, skipPermissions: false,
                         isolateWorktree: false, initialInput: prPrompt(pr))
        }
    }

    // MARK: - Full-text transcript search (juancode-wx9)

    /// The current search query (bound to the SearchPanel text field).
    @Published var searchQuery = ""
    /// Hits for the most recently completed search, in rank order.
    @Published var searchResults: [SearchHit] = []
    /// True while a search is in flight (for a "Searching…" affordance).
    @Published var searching = false
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
    @Published var beadsByCwd: [String: BeadsResult] = [:]
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
                // Write it as if typed: idle → runs now, busy → queued by the CLI.
                session.write("\(prompt)\r")
            } else {
                // No live session for this folder — start one seeded with the prompt.
                await create(provider: .claude, cwd: cwd, skipPermissions: false,
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

    /// PRs under continuous watch, keyed by `TrackedPr.key(cwd:number:)`. The poll
    /// loop diffs each one's `gh` activity and feeds fixes into its agent session.
    @Published var tracked: [String: TrackedPr] = [:]
    /// How often the poll loop revisits every tracked PR.
    private let trackPollInterval: Duration = .seconds(20)
    private var trackLoop: Task<Void, Never>?

    /// Look up a tracked PR by folder + number (for the "Track / Tracking" toggle).
    func trackedPr(cwd: String, number: Int) -> TrackedPr? {
        tracked[TrackedPr.key(cwd: cwd, number: number)]
    }

    /// Start tracking a PR: spawn a dedicated Claude session seeded with the PR's
    /// context and the auto-fix-vs-escalate contract, register it, and ensure the
    /// poll loop is running. No-op if already tracked.
    func trackPr(_ pr: PullRequest, cwd: String) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard tracked[key] == nil else { return }
        Task {
            let seed = trackSeedPrompt(number: pr.number, title: pr.title,
                                       branch: pr.branch, url: pr.url)
            guard let session = await create(provider: .claude, cwd: cwd, skipPermissions: false,
                                             isolateWorktree: false, initialInput: seed) else { return }
            tracked[key] = TrackedPr(
                number: pr.number, title: pr.title, branch: pr.branch, url: pr.url,
                cwd: cwd, sessionId: session.id)
            startTrackLoop()
        }
    }

    /// Stop tracking a PR. Leaves its agent session alone (the user may still want
    /// it); just drops it from the watch list. Stops the loop when none remain.
    func untrackPr(_ id: String) {
        tracked[id] = nil
        if tracked.isEmpty { trackLoop?.cancel(); trackLoop = nil }
    }

    /// Dismiss a surfaced decision once the user has dealt with it.
    func resolveNotification(prId: String, notificationId: String) {
        tracked[prId]?.notifications.removeAll { $0.id == notificationId }
    }

    private func startTrackLoop() {
        guard trackLoop == nil else { return }
        trackLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollTrackedOnce()
                try? await Task.sleep(for: self?.trackPollInterval ?? .seconds(20))
            }
        }
    }

    /// One pass over every tracked PR: fetch its `gh` activity off the main actor,
    /// classify what changed, inject auto-fix prompts into the agent session, and
    /// raise notifications for changes that need a human decision.
    func pollTrackedOnce() async {
        for (key, pr) in tracked {
            let cwd = pr.cwd, number = pr.number
            guard let activity = await Task.detached(priority: .utility, operation: {
                await getPrActivity(cwd, number: number)
            }).value else { continue }

            // The entry may have been untracked while we were off-actor.
            guard var entry = tracked[key] else { continue }
            let result = classifyPrActivity(prev: entry.snapshot, activity: activity)
            entry.snapshot = result.snapshot
            entry.lastPolledAt = nowMs()

            var fixReasons: [String] = []
            for event in result.events {
                switch event {
                case .autoFix(let reason):
                    fixReasons.append(reason)
                case .needsDecision(let reason):
                    entry.notifications.append(TrackNotification(
                        id: UUID().uuidString, prNumber: number,
                        message: reason, createdAt: nowMs()))
                }
            }
            if !fixReasons.isEmpty, let session = liveSession(entry.sessionId) {
                // Write it as if typed: idle → runs now, busy → queued by the CLI.
                let prompt = autoFixPrompt(number: number, branch: entry.branch, reasons: fixReasons)
                session.write("\(prompt)\r")
            }
            tracked[key] = entry
        }
    }

    /// Flip "accept all" (skip permission prompts) on a live session. There's no
    /// way to change a running CLI's permission level in place, so the registry
    /// resume-restarts the pty under the same juancode id, preserving the
    /// conversation + scrollback. Mirrors the WS `setSkipPermissions` path.
    func setSkipPermissions(_ id: String, to skip: Bool) async {
        guard isLive(id), !flippingPermissions.contains(id) else { return }
        flippingPermissions.insert(id)
        defer { flippingPermissions.remove(id) }
        do {
            // Off the main actor: kills the old pty and forkpty()s a new one.
            let registry = appState.registry
            _ = try await Task.detached(priority: .userInitiated) {
                try await registry.setSkipPermissions(id, skipPermissions: skip, cols: 80, rows: 24)
            }.value
            refresh()
        } catch {
            errorMessage = "Failed to change permissions: \(error)"
        }
    }

    /// Revive an exited session (mirrors the WS `reactivate` path).
    func reactivate(_ id: String) async {
        if isLive(id) { return }
        guard var meta = appState.store.get(id) else { return }
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
            return
        }
        do {
            let prior = appState.store.getScrollback(id) ?? []
            let seed: [UInt8] = prior.isEmpty
                ? [] : prior + Array("\r\n\u{1B}[2m── session resumed ──\u{1B}[0m\r\n".utf8)
            _ = try appState.registry.resume(meta, cols: 80, rows: 24, priorScrollback: seed)
            refresh()
        } catch {
            errorMessage = "Failed to resume: \(error)"
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

    // MARK: - Changes panel (working-tree diff + inline comments + git actions) — juancode-3bq

    /// Per-session working-tree diff cache, loaded lazily by the ChangesPanel and
    /// refreshed on demand. Mirrors the web's per-session `useQuery(["diff", …])`.
    @Published var diffBySession: [String: DiffResult] = [:]
    /// Per-session git state (branch / ahead / dirty / remote) backing the git CTAs.
    @Published var gitStateBySession: [String: GitState] = [:]
    /// Per-session inline review comments. Held in-memory (in-process, no server
    /// round-trip) — they're a staging area pasted into the agent on "submit".
    @Published var commentsBySession: [String: [DiffComment]] = [:]
    /// Sessions whose diff is currently loading, so the panel can show a spinner.
    @Published var diffLoading: Set<String> = []
    /// A transient git-action status line per session (commit/push result or error).
    @Published var gitNoteBySession: [String: GitNote] = [:]

    private var diffInFlight: Set<String> = []

    struct GitNote: Equatable { var ok: Bool; var text: String }

    func diff(_ id: String) -> DiffResult? { diffBySession[id] }
    func gitState(_ id: String) -> GitState? { gitStateBySession[id] }
    func comments(_ id: String) -> [DiffComment] { commentsBySession[id] ?? [] }

    /// The cwd a session's changes panel operates on (its own working directory).
    private func cwd(of id: String) -> String? {
        liveSession(id)?.meta.cwd ?? appState.store.get(id)?.cwd
    }

    /// Load (or refresh) the working-tree diff + git state for a session, off the
    /// main actor (both shell out to git). Coalesces concurrent calls. Mirrors
    /// `loadPrs`.
    func loadChanges(_ id: String) {
        guard let cwd = cwd(of: id), !diffInFlight.contains(id) else { return }
        diffInFlight.insert(id)
        diffLoading.insert(id)
        Task {
            async let d = Task.detached(priority: .utility) { try? await getDiff(cwd) }.value
            async let g = Task.detached(priority: .utility) { await getGitState(cwd) }.value
            let (diff, state) = await (d, g)
            if let diff { diffBySession[id] = diff }
            gitStateBySession[id] = state
            diffLoading.remove(id)
            diffInFlight.remove(id)
        }
    }

    /// Spawn the user's real editor (`$VISUAL`/`$EDITOR`, default nvim) on `file`,
    /// confined to the session's cwd, via an ephemeral pty. Returns the live pty for
    /// the overlay to render + drive, or nil if there's no cwd or the spawn/path
    /// check fails (a status note is set on failure). Mirrors the web `openEditor`
    /// handshake — the native overlay renders the returned pty directly (no WS hop).
    func openEditor(_ id: String, file: String, cols: Int, rows: Int) -> EphemeralPty? {
        guard let cwd = cwd(of: id) else {
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

    // MARK: - Bottom terminal panel (per-workdir)

    /// VS Code-style bottom shell terminals, keyed by FOLDER cwd (not session id):
    /// every session in a folder shares the same set of terminals, so switching
    /// between sessions in one folder keeps the terminals alive and identical. The
    /// pure tab/pane layout lives in `TerminalPanelModel`; the live shell ptys are
    /// held alongside it, keyed by pane id. (Cross-session-switch persistence
    /// niceties are tracked separately in juancode-iwi.)
    @Published var terminalPanels: [String: TerminalPanelModel] = [:]
    /// Live shell ptys for every open pane, keyed by pane id. Shared across all
    /// folders; entries are removed + killed when their pane closes.
    private var shellPtys: [TerminalPaneID: EphemeralPty] = [:]

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

    /// Add an inline comment to a session's staging area.
    func addComment(_ id: String, file: String, side: CommentSide, line: Int, endLine: Int, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let c = DiffComment(
            id: UUID().uuidString, sessionId: id, file: file, side: side,
            line: min(line, endLine), endLine: max(line, endLine),
            body: trimmed, createdAt: Int(Date().timeIntervalSince1970 * 1000))
        commentsBySession[id, default: []].append(c)
    }

    /// Remove a staged inline comment.
    func deleteComment(_ id: String, commentId: String) {
        commentsBySession[id]?.removeAll { $0.id == commentId }
    }

    /// Submit the batched review: compose the comments (+ closing note) into one
    /// prompt and inject it into the session as if typed, then clear them. Mirrors
    /// the web "Submit review" (which bracket-pastes into the pty); here we write it
    /// straight to the live session. No-op without a live session.
    func submitReview(_ id: String, finalNote: String) {
        guard let session = liveSession(id) else {
            gitNoteBySession[id] = GitNote(ok: false, text: "Session isn't live — can't send review.")
            return
        }
        let files = diffBySession[id]?.files ?? []
        let prompt = composeReviewPrompt(files: files, comments: comments(id), finalNote: finalNote)
        guard !prompt.isEmpty else { return }
        // Write as if typed (idle → runs, busy → queued by the CLI). The user
        // reviews the multi-line prompt and presses Enter to send.
        session.write(prompt)
        commentsBySession[id] = []
    }

    /// Stage everything and commit, off the main actor. Refreshes the diff + git
    /// state and surfaces a status note on success/failure. Mirrors the web commit
    /// mutation in GitActions.
    func commit(_ id: String, message: String) async {
        guard let cwd = cwd(of: id) else { return }
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
        guard let cwd = cwd(of: id) else { return }
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
        guard let cwd = cwd(of: id) else { return nil }
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
        guard let cwd = cwd(of: id) else { return nil }
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
    @Published var providerStatus: [ProviderStatus]?
    /// True while a status check is in flight (the CLIs health-check every server,
    /// so this can take a few seconds). Backs the panel's "checking…" affordance.
    @Published var statusLoading = false

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

    func delete(_ id: String) {
        let meta = appState.store.get(id)
        appState.registry.get(id)?.kill()
        appState.store.delete(id)
        activityCancels[id]?(); activityCancels[id] = nil
        if selection == id { selection = nil }
        refresh()
        if let wt = meta?.worktreePath {
            Task { try? await removeWorktree(wt) }
        }
    }
}
