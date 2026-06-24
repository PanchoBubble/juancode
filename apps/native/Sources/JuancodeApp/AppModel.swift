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
