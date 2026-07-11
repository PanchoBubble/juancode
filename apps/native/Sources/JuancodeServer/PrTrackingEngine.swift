import Foundation
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// Tracked-PR engine (juancode-bt2 / juancode-b4m): the single owner of the
/// tracked-PR watch list, its poll loop, and its persistence. The SwiftUI
/// `AppModel` is a facade over this actor (a read-only mirror fed by
/// `subscribe`), and the remote web/phone client drives it over the wire —
/// one list, one poller, no double-driving.
///
/// The semantics: clicking "Track" spawns a dedicated agent session seeded with
/// the PR context + auto-fix-vs-escalate contract (`trackSeedPrompt`); a 60s
/// poll loop diffs each PR's `gh` activity (`classifyPrActivity`), injects
/// `autoFixPrompt`s into the agent session for auto-fixable changes, and raises
/// `TrackNotification`s for changes that need a human decision. The pure
/// classification + prompt logic is reused verbatim from
/// `JuancodeServices/TrackedPr.swift` — this layer only owns the watch list, the
/// session plumbing, persistence, and broadcasting changes to subscribers.
///
/// One process-wide instance lives on `AppState`; every `WebSocketConnection`
/// subscribes to it for status/notification pushes and routes the tracking client
/// messages through it. The watch list persists in the SQLite `tracked_prs`
/// table (`TrackedPrStore`), so it survives a restart of either surface.
public actor PrTrackingEngine {
    /// A change observers should react to: either the full watch list moved (status
    /// refresh) or a single needs-decision escalation fired (notification ping).
    public enum Change: Sendable {
        case tracked([TrackedPr])
        case notification(trackedId: String, prNumber: Int, notification: TrackNotification)
    }

    private let registry: SessionRegistry
    private let store: GRDBStore

    /// PRs under continuous watch, keyed by `TrackedPr.key(cwd:number:)`.
    private var tracked: [String: TrackedPr] = [:]
    private var pollLoop: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(60)

    private var nextObserverToken = 0
    private var observers: [Int: @Sendable (Change) -> Void] = [:]

    /// Debounce window for webhook-triggered refreshes: a single push fires
    /// several GitHub events within moments, and each should NOT cost its own
    /// round of `gh` spawns — the burst coalesces into one refresh per PR.
    private let webhookDebounce: Duration
    /// In-flight debounce timers, keyed by tracked-PR id.
    private var pendingRefresh: [String: Task<Void, Never>] = [:]

    /// Test seam: observes each actual (post-guard) refresh so debounce
    /// coalescing is assertable without a live `gh`.
    private var refreshProbe: (@Sendable (String) -> Void)?
    func setRefreshProbe(_ probe: @escaping @Sendable (String) -> Void) { refreshProbe = probe }

    /// The pre-SQLite persistence key (juancode-b4m). Only read once, to import a
    /// legacy watch list into the store; absence of the key is the migration marker.
    private static let legacyDefaultsKey = "juancode.trackedPrs.v1"

    /// `legacyDefaultsSuite` is a seam for tests — the one-time legacy import reads
    /// (and then deletes) the old UserDefaults blob from that suite instead of
    /// `.standard`. (A suite name, not a `UserDefaults` instance, because the latter
    /// isn't Sendable and can't cross into the actor init.)
    public init(registry: SessionRegistry, store: GRDBStore, legacyDefaultsSuite: String? = nil,
                webhookDebounce: Duration = .seconds(2)) {
        self.registry = registry
        self.store = store
        self.webhookDebounce = webhookDebounce
        let defaults = legacyDefaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        // Restore the persisted watch list synchronously in init (the actor's
        // isolated state is initialised here), then kick the poll loop off-actor.
        let payloads = store.loadTrackedPrPayloads()
        if payloads.isEmpty {
            // One-time import of the legacy UserDefaults list. Once imported the key
            // is removed, so a later empty store (user untracked everything) can never
            // resurrect a stale defaults copy.
            if let data = defaults.data(forKey: Self.legacyDefaultsKey),
               let list = try? JSONDecoder().decode([TrackedPr].self, from: data),
               !list.isEmpty {
                for pr in list { tracked[pr.id] = pr }
                store.replaceTrackedPrPayloads(Self.encodePayloads(tracked))
                defaults.removeObject(forKey: Self.legacyDefaultsKey)
            }
        } else {
            for (id, payload) in payloads {
                if let pr = try? JSONDecoder().decode(TrackedPr.self, from: Data(payload.utf8)) {
                    tracked[id] = pr
                }
            }
        }
        if !tracked.isEmpty {
            Task { await self.startLoop() }
        }
    }

    // MARK: - subscriptions

    /// Subscribe to watch-list + notification changes. The new subscriber is
    /// immediately handed the current snapshot. Returns a cancel handle.
    public func subscribe(_ onChange: @escaping @Sendable (Change) -> Void) -> @Sendable () -> Void {
        let token = nextObserverToken
        nextObserverToken += 1
        observers[token] = onChange
        onChange(.tracked(snapshot()))
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeObserver(token) }
        }
    }

    private func removeObserver(_ token: Int) { observers[token] = nil }

    /// Most-recently-polled-first, matching `AppModel.trackedList`.
    public func list() -> [TrackedPr] { snapshot() }

    private func snapshot() -> [TrackedPr] {
        tracked.values.sorted {
            ($0.lastPolledAt ?? 0, $0.number) > ($1.lastPolledAt ?? 0, $1.number)
        }
    }

    private func broadcastTracked() {
        let snap = snapshot()
        for o in observers.values { o(.tracked(snap)) }
    }

    private func broadcastNotification(trackedId: String, prNumber: Int, _ n: TrackNotification) {
        for o in observers.values { o(.notification(trackedId: trackedId, prNumber: prNumber, notification: n)) }
    }

    // MARK: - track / untrack

    /// Start tracking a PR: spawn a dedicated Claude session seeded with the PR's
    /// context + auto-fix-vs-escalate contract, register it, and ensure the poll
    /// loop is running. Returns the new entry (so the GUI can select its spawned
    /// session); nil when already tracked (no-op) or the spawn failed.
    @discardableResult
    public func track(_ pr: PullRequest, cwd: String) -> TrackedPr? {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard tracked[key] == nil else { return nil }
        let seed = trackSeedPrompt(number: pr.number, title: pr.title, branch: pr.branch, url: pr.url)
        let grid = (cols: 120, rows: 32)
        guard let session = try? registry.create(
            provider: .claude, cwd: cwd, cols: grid.cols, rows: grid.rows,
            opts: SpawnOptions(skipPermissions: true, model: "opus")
        ) else { return nil }
        if !seed.isEmpty { session.autoSubmit(seed) }
        let entry = TrackedPr(
            number: pr.number, title: pr.title, branch: pr.branch, url: pr.url,
            cwd: cwd, sessionId: session.id)
        tracked[key] = entry
        persist()
        broadcastTracked()
        startLoop()
        // Resolve the repo's owner/name off-actor (a `gh` round-trip) so track()
        // stays snappy; webhook matching only needs it eventually, and a missed
        // resolve here is backfilled on the next poll.
        Task { [weak self] in
            guard let nwo = await getRepoNwo(cwd) else { return }
            await self?.setRepoNwo(key, nwo)
        }
        return entry
    }

    private func setRepoNwo(_ id: String, _ nwo: String) {
        guard tracked[id] != nil, tracked[id]?.repoNwo == nil else { return }
        tracked[id]?.repoNwo = nwo
        persist()
    }

    /// Stop tracking a PR. Leaves its agent session alone; just drops it from the
    /// watch list. Stops the loop when none remain.
    public func untrack(_ id: String) {
        guard tracked[id] != nil else { return }
        tracked[id] = nil
        pendingRefresh[id]?.cancel()
        pendingRefresh[id] = nil
        persist()
        broadcastTracked()
        if tracked.isEmpty { pollLoop?.cancel(); pollLoop = nil }
    }

    /// Dismiss a surfaced decision once the user has dealt with it.
    public func resolveNotification(trackedId: String, notificationId: String) {
        guard tracked[trackedId] != nil else { return }
        tracked[trackedId]?.notifications.removeAll { $0.id == notificationId }
        persist()
        broadcastTracked()
    }

    // MARK: - poll loop

    private func startLoop() {
        guard pollLoop == nil else { return }
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(60))
            }
        }
    }

    /// One pass over every tracked PR: fetch its `gh` activity, classify what
    /// changed, inject auto-fix prompts into the agent session, and raise
    /// notifications for changes that need a human decision.
    func pollOnce() async {
        // Fetch every tracked PR's activity concurrently (juancode-hmu): a pass is
        // one round of parallel `gh` spawns instead of N sequential ones.
        // `getViewerLogin` is process-cached after the first call, so the fan-out
        // only multiplies the `gh pr view` round-trips. The `activity` + `viewer`
        // for one PR are still fetched together so the classifier can ignore the
        // agent's own comments (no echo loop). Results are applied serially below,
        // back on the actor.
        let toPoll = tracked.values.map { (key: $0.id, cwd: $0.cwd, number: $0.number, nwo: $0.repoNwo) }
        guard !toPoll.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, PrActivity?, String, String?).self) { group in
            for item in toPoll {
                group.addTask(priority: .utility) {
                    async let activity = getPrActivity(item.cwd, number: item.number)
                    async let viewer = getViewerLogin(item.cwd)
                    async let nwo = resolveRepoNwo(current: item.nwo, cwd: item.cwd)
                    return (item.key, await activity, await viewer, await nwo)
                }
            }
            var out: [(String, PrActivity?, String, String?)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (key, activity, viewerLogin, repoNwo) in fetched {
            guard let activity else { continue }
            await apply(key: key, activity: activity, viewerLogin: viewerLogin, repoNwo: repoNwo)
        }
        persist()
        broadcastTracked()
    }

    /// Refresh ONE tracked PR right now: fetch its `gh` activity and run it
    /// through the same classify → inject → notify path a poll pass uses. This is
    /// what a webhook ultimately triggers (the event is a trigger, not a payload).
    /// No-op when the id isn't tracked or the fetch fails (the poll loop retries).
    public func refreshPr(_ id: String) async {
        guard let entry = tracked[id] else { return }
        refreshProbe?(id)
        async let activityFetch = getPrActivity(entry.cwd, number: entry.number)
        async let viewerFetch = getViewerLogin(entry.cwd)
        async let nwoFetch = resolveRepoNwo(current: entry.repoNwo, cwd: entry.cwd)
        let (activity, viewerLogin, repoNwo) = await (activityFetch, viewerFetch, nwoFetch)
        guard let activity else { return }
        await apply(key: id, activity: activity, viewerLogin: viewerLogin, repoNwo: repoNwo)
        persist()
        broadcastTracked()
    }

    // MARK: - webhook ingest

    /// Tracked PRs matching a webhook's repo identity + PR number. The stored
    /// `repoNwo` is compared case-insensitively (GitHub slugs are); entries that
    /// predate repo identity (nil `repoNwo`, not yet backfilled) fall back to the
    /// owner/name embedded in their PR url.
    public func findByRepoNumber(_ nwo: String, number: Int) -> [TrackedPr] {
        let want = nwo.lowercased()
        return tracked.values.filter { entry in
            guard entry.number == number else { return false }
            if let stored = entry.repoNwo { return stored.lowercased() == want }
            guard let slug = repoSlug(fromPrUrl: entry.url) else { return false }
            return "\(slug.owner)/\(slug.name)".lowercased() == want
        }
    }

    /// Webhook entry point: schedule a refresh for every tracked PR matching the
    /// event's repo + number. No-op when nothing tracked matches. Bursts (one push
    /// fires several GitHub events) coalesce into a single refresh per PR via
    /// `webhookDebounce`. Returns how many tracked PRs matched.
    @discardableResult
    public func ingestWebhook(repo nwo: String, number: Int) -> Int {
        let matches = findByRepoNumber(nwo, number: number)
        for pr in matches { scheduleRefresh(pr.id) }
        return matches.count
    }

    private func scheduleRefresh(_ id: String) {
        // A refresh is already pending for this PR — the new event folds into it.
        guard pendingRefresh[id] == nil else { return }
        pendingRefresh[id] = Task { [weak self, delay = webhookDebounce] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runPendingRefresh(id)
        }
    }

    private func runPendingRefresh(_ id: String) async {
        pendingRefresh[id] = nil
        await refreshPr(id)
    }

    // MARK: - per-PR apply (shared by poll + refresh)

    /// Apply one PR's freshly-fetched activity: advance the baseline, inject
    /// auto-fix prompts into the driving session, raise needs-decision
    /// notifications, untrack on merge/close. Does NOT persist or broadcast the
    /// watch list — the caller does, so a poll pass batches one write for N PRs.
    private func apply(key: String, activity: PrActivity, viewerLogin: String,
                       repoNwo: String?) async {
        // The entry may have been untracked while the fetch was off-actor.
        guard var entry = tracked[key] else { return }
        if entry.repoNwo == nil, let repoNwo { entry.repoNwo = repoNwo }
        let number = entry.number
        let result = classifyPrActivity(prev: entry.snapshot, activity: activity, viewerLogin: viewerLogin)
        entry.snapshot = result.snapshot
        entry.lastPolledAt = nowMs()

        // Terminal: the PR merged/closed. Ping observers once (so the client can
        // toast / notify), then drop it from the watch list. Its session is left alone.
        var closedReason: String?
        for case .closed(let r) in result.events { closedReason = r; break }
        if let reason = closedReason {
            broadcastNotification(trackedId: key, prNumber: number, TrackNotification(
                id: UUID().uuidString, prNumber: number, message: reason, createdAt: nowMs()))
            untrack(key)
            return
        }

        var fixReasons: [String] = []
        var newNotifications: [TrackNotification] = []
        for event in result.events {
            switch event {
            case .autoFix(let reason):
                fixReasons.append(reason)
            case .needsDecision(let reason):
                newNotifications.append(TrackNotification(
                    id: UUID().uuidString, prNumber: number, message: reason, createdAt: nowMs()))
            case .closed:
                break  // handled above
            }
        }
        entry.notifications.append(contentsOf: newNotifications)

        if !fixReasons.isEmpty {
            let prompt = autoFixPrompt(number: number, branch: entry.branch, reasons: fixReasons)
            if let session = registry.get(entry.sessionId) {
                session.submit(prompt)
            } else {
                // The driving session is offline (typically after a restart).
                // Revive it lazily, then seed the fix via autoSubmit.
                _ = await reviveSession(entry.sessionId, registry: registry, store: store)
                if let session = registry.get(entry.sessionId) {
                    session.autoSubmit(prompt)
                } else if let fresh = try? registry.create(
                    provider: .claude, cwd: entry.cwd, cols: 120, rows: 32,
                    opts: SpawnOptions(skipPermissions: true, model: "opus")
                ) {
                    // The original conversation couldn't be resumed (e.g. nothing
                    // recoverable). Rather than stall, open a fresh session seeded
                    // with the PR context, rebind tracking to it, and queue the fix.
                    // Future polls target the new session.
                    let seed = trackSeedPrompt(number: number, title: entry.title,
                                               branch: entry.branch, url: entry.url)
                    if !seed.isEmpty { fresh.autoSubmit(seed) }
                    fresh.autoSubmit(prompt)
                    entry.sessionId = fresh.id
                } else {
                    // Even a fresh spawn failed — surface it so the tracked-PR UI
                    // shows the work is stuck rather than dropping it. Dedupe so a
                    // persistently-failing session doesn't raise the same
                    // notification on every poll.
                    let offlineMsg = "Auto-fix needed, but the driving session is offline and couldn't be resumed or respawned."
                    if !entry.notifications.contains(where: { $0.message == offlineMsg }) {
                        let n = TrackNotification(id: UUID().uuidString, prNumber: number,
                                                  message: offlineMsg, createdAt: nowMs())
                        entry.notifications.append(n)
                        newNotifications.append(n)
                    }
                }
            }
        }

        tracked[key] = entry
        for n in newNotifications { broadcastNotification(trackedId: key, prNumber: number, n) }
    }

    // MARK: - persistence (SQLite `tracked_prs` via TrackedPrStore)

    private func persist() {
        store.replaceTrackedPrPayloads(Self.encodePayloads(tracked))
    }

    private static func encodePayloads(_ tracked: [String: TrackedPr]) -> [String: String] {
        var payloads: [String: String] = [:]
        for (id, pr) in tracked {
            if let data = try? JSONEncoder().encode(pr) {
                payloads[id] = String(decoding: data, as: UTF8.self)
            }
        }
        return payloads
    }
}

/// Lazy repo-identity backfill: entries tracked before `repoNwo` existed resolve
/// it alongside their next activity fetch; entries that already have it skip the
/// extra `gh` round-trip entirely.
private func resolveRepoNwo(current: String?, cwd: String) async -> String? {
    if let current { return current }
    return await getRepoNwo(cwd)
}
