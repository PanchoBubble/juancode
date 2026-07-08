import Foundation
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// Server-side tracked-PR engine (juancode-bt2): mirrors the in-process tracking
/// the SwiftUI `AppModel` runs, but exposed over the wire so the remote web/phone
/// client (`apps/web`) can start/stop tracking and observe status + needs-decision
/// escalations.
///
/// The semantics are a faithful port of `AppModel`'s PR tracking: clicking "Track"
/// spawns a dedicated agent session seeded with the PR context + auto-fix-vs-escalate
/// contract (`trackSeedPrompt`); a 20s poll loop diffs each PR's `gh` activity
/// (`classifyPrActivity`), injects `autoFixPrompt`s into the agent session for
/// auto-fixable changes, and raises `TrackNotification`s for changes that need a
/// human decision. The pure classification + prompt logic is reused verbatim from
/// `JuancodeServices/TrackedPr.swift` — this layer only owns the watch list, the
/// session plumbing, and broadcasting changes to subscribers.
///
/// One process-wide instance lives on `AppState`; every `WebSocketConnection`
/// subscribes to it for status/notification pushes and routes the tracking client
/// messages through it. Persistence uses the same `UserDefaults` key as the GUI so
/// the watch list survives a restart in either surface.
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
    private let pollInterval: Duration = .seconds(20)

    private var nextObserverToken = 0
    private var observers: [Int: @Sendable (Change) -> Void] = [:]

    /// Shared with the GUI (`AppModel.trackedDefaultsKey`) so a single watch list is
    /// restored regardless of which surface last wrote it.
    private static let defaultsKey = "juancode.trackedPrs.v1"

    public init(registry: SessionRegistry, store: GRDBStore) {
        self.registry = registry
        self.store = store
        // Restore the persisted watch list synchronously in init (the actor's
        // isolated state is initialised here), then kick the poll loop off-actor.
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([TrackedPr].self, from: data) {
            for pr in list { tracked[pr.id] = pr }
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

    // MARK: - track / untrack (mirror AppModel.trackPr / untrackPr)

    /// Start tracking a PR: spawn a dedicated Claude session seeded with the PR's
    /// context + auto-fix-vs-escalate contract, register it, and ensure the poll
    /// loop is running. No-op if already tracked.
    public func track(_ pr: PullRequest, cwd: String) {
        let key = TrackedPr.key(cwd: cwd, number: pr.number)
        guard tracked[key] == nil else { return }
        let seed = trackSeedPrompt(number: pr.number, title: pr.title, branch: pr.branch, url: pr.url)
        let grid = (cols: 120, rows: 32)
        guard let session = try? registry.create(
            provider: .claude, cwd: cwd, cols: grid.cols, rows: grid.rows,
            opts: SpawnOptions(skipPermissions: true, model: "opus")
        ) else { return }
        if !seed.isEmpty { session.autoSubmit(seed) }
        tracked[key] = TrackedPr(
            number: pr.number, title: pr.title, branch: pr.branch, url: pr.url,
            cwd: cwd, sessionId: session.id)
        persist()
        broadcastTracked()
        startLoop()
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

    // MARK: - poll loop (mirror AppModel.pollTrackedOnce)

    private func startLoop() {
        guard pollLoop == nil else { return }
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(20))
            }
        }
    }

    /// One pass over every tracked PR: fetch its `gh` activity, classify what
    /// changed, inject auto-fix prompts into the agent session, and raise
    /// notifications for changes that need a human decision.
    func pollOnce() async {
        for (key, pr) in tracked {
            let cwd = pr.cwd, number = pr.number
            guard let activity = await getPrActivity(cwd, number: number) else { continue }
            // The authenticated `gh` login, so the classifier ignores the agent's own
            // comments/reviews and doesn't echo-fire on them.
            let viewerLogin = await getViewerLogin(cwd)
            guard var entry = tracked[key] else { continue } // untracked while off-actor

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
                    } else {
                        let offlineMsg = "Auto-fix needed, but the driving session is offline and couldn't be resumed."
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

    // MARK: - persistence (shares AppModel's UserDefaults key)

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(tracked.values)) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
