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

    /// The pre-SQLite persistence key (juancode-b4m). Only read once, to import a
    /// legacy watch list into the store; absence of the key is the migration marker.
    private static let legacyDefaultsKey = "juancode.trackedPrs.v1"

    /// `legacyDefaultsSuite` is a seam for tests — the one-time legacy import reads
    /// (and then deletes) the old UserDefaults blob from that suite instead of
    /// `.standard`. (A suite name, not a `UserDefaults` instance, because the latter
    /// isn't Sendable and can't cross into the actor init.)
    public init(registry: SessionRegistry, store: GRDBStore, legacyDefaultsSuite: String? = nil) {
        self.registry = registry
        self.store = store
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
        return entry
    }

    /// Stop tracking a PR. Leaves its agent session alone; just drops it from the
    /// watch list. Stops the loop when none remain.
    public func untrack(_ id: String) {
        guard tracked[id] != nil else { return }
        tracked[id] = nil
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
        let toPoll = tracked.values.map { (key: $0.id, cwd: $0.cwd, number: $0.number) }
        guard !toPoll.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, PrActivity?, String).self) { group in
            for item in toPoll {
                group.addTask(priority: .utility) {
                    async let activity = getPrActivity(item.cwd, number: item.number)
                    async let viewer = getViewerLogin(item.cwd)
                    return (item.key, await activity, await viewer)
                }
            }
            var out: [(String, PrActivity?, String)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (key, activity, viewerLogin) in fetched {
            guard let activity else { continue }
            // The entry may have been untracked while we were off-actor.
            guard var entry = tracked[key] else { continue }
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
                continue
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
        persist()
        broadcastTracked()
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
