import Foundation

/// Global pause: put every live session to sleep at once, and bring exactly that
/// set back on play.
///
/// Pause reuses the per-session sleep path (kill the CLI tree, keep the row, its
/// scrollback and its resume id), so the RAM of ~300MB per live session is
/// actually returned — that is the point of the button. The cost is that an
/// in-flight turn is lost: play resumes the conversation with `--resume`, it does
/// not continue mid-thought.
///
/// The paused set has to be recorded separately from `meta.dormant`, which is too
/// broad to resume from: the idle reaper and a graceful quit both set it, so
/// "everything dormant" would sweep sessions the user put to sleep themselves
/// weeks ago back into life on the next play.
public enum GlobalPause {
    /// One session as the pause planner sees it. Deliberately not `SessionMeta` —
    /// what matters is liveness and whether it is a real agent.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let isLive: Bool
        /// Editor/terminal panes are ptys too, but they hold no conversation to
        /// resume: sleeping one loses the buffer and play brings back an empty
        /// shell. They stay running.
        public let isAgent: Bool

        public init(id: String, isLive: Bool, isAgent: Bool) {
            self.id = id
            self.isLive = isLive
            self.isAgent = isAgent
        }
    }

    /// The sessions a pause should sleep, in the given order. Everything live and
    /// agent-backed goes, including the selected one — "pause all" that leaves the
    /// pane you're looking at burning CPU isn't a pause.
    public static func targets(_ candidates: [Candidate]) -> [String] {
        candidates.filter { $0.isLive && $0.isAgent }.map(\.id)
    }

    /// The sessions a play should revive: the recorded paused set, minus anything
    /// that came back on its own (clicked, resumed by the Oracle) or vanished from
    /// the sidebar entirely while paused.
    ///
    /// `focus` is floated to the front so the pane you are looking at is the first
    /// one live rather than whichever row happened to sort first.
    public static func revivals(paused: Set<String>, present: [Candidate],
                                focus: String?) -> [String] {
        let ordered = present.filter { paused.contains($0.id) && !$0.isLive }.map(\.id)
        guard let focus, ordered.contains(focus) else { return ordered }
        return [focus] + ordered.filter { $0 != focus }
    }

    /// Deal ids round-robin into at most `lanes` lanes.
    ///
    /// Each revival is a real `claude --resume` process, so the lane count is what
    /// bounds the RAM and pty burst of a play after a big pause — the same bound
    /// the launch sweep applies for the same reason. Round-robin rather than
    /// contiguous chunks so the head of the list (the focused pane first) starts
    /// early instead of queueing behind a lane's whole share.
    public static func lanes(_ ids: [String], lanes count: Int) -> [[String]] {
        guard !ids.isEmpty, count > 0 else { return [] }
        var out: [[String]] = Array(repeating: [], count: min(count, ids.count))
        for (i, id) in ids.enumerated() { out[i % out.count].append(id) }
        return out
    }
}

/// Where the paused set lives, and the one object both surfaces read it through.
///
/// The set used to be a `Set<String>` on the SwiftUI model, persisted to
/// `UserDefaults`, which made it desktop-only: the phone could not see what the
/// desktop had paused, and a play from the phone had no set to revive. Both
/// surfaces now read this book — the local toolbar button because the model holds
/// it, and a remote client because the `/ws` surface publishes it as `pauseState`
/// and mutates it through the same object.
///
/// It is deliberately NOT derived from `meta.dormant`. Dormancy has four other
/// producers (the idle reaper, the live-session cap, a graceful quit, and a
/// per-session sleep somebody asked for), and `SessionSleepReason` — the field that
/// would tell them apart — is not persisted on the row, only logged. Reviving
/// everything dormant would wake sessions the user slept themselves weeks ago,
/// which is the bug `GlobalPause`'s own note has warned about since it was written.
///
/// One instance per launch, reached through `CoreClient.globalPause`, so a pause
/// taken on either surface is the same set the other one plays.
public final class GlobalPauseBook: @unchecked Sendable {
    /// Persistence seam. Survives a quit, which is the point: quitting while paused
    /// is half of why anyone pauses, and losing the set would strand every one of
    /// those sessions asleep with nothing to tell them from a sleep you asked for.
    public struct Storage: Sendable {
        public let load: @Sendable () -> [String]
        public let save: @Sendable ([String]) -> Void

        public init(load: @escaping @Sendable () -> [String],
                    save: @escaping @Sendable ([String]) -> Void) {
            self.load = load
            self.save = save
        }

        /// Where the desktop kept the set before this: a `UserDefaults` key, read
        /// once below so a pause taken by the previous build still plays.
        public static let legacyDefaultsKey = "juancode.pausedSessions"

        /// A file beside the core's rows, which is what makes the set follow the DATA
        /// DIR rather than the process's defaults domain. Two launches over two data
        /// dirs (the conformance harness boots a core on a fresh one every run) must
        /// not share a paused set: a run interrupted mid-pause would otherwise hand
        /// the next one a set of ids it has never heard of.
        public static func dataDir(_ dir: String = Config.dataDir) -> Storage {
            let path = (dir as NSString).appendingPathComponent("global-pause.json")
            return Storage(
                load: {
                    guard let data = FileManager.default.contents(atPath: path) else {
                        // First run on this build: inherit the pause the old key holds.
                        return UserDefaults.standard.stringArray(forKey: legacyDefaultsKey) ?? []
                    }
                    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
                },
                save: { ids in
                    // Cleared in the same breath, so the fallback above cannot
                    // resurrect a set a later play already emptied.
                    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                    try? FileManager.default.createDirectory(
                        atPath: dir, withIntermediateDirectories: true)
                    guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                })
        }

        /// Nothing persisted — for tests, and for a core whose pause should not
        /// outlive the process.
        public static func memory() -> Storage {
            let box = MemoryBox()
            return Storage(load: { box.read() }, save: { box.write($0) })
        }
    }

    private let storage: Storage
    private let lock = NSLock()
    private var ids: Set<String>
    private var listeners: [Int: @Sendable (Set<String>) -> Void] = [:]
    private var nextToken = 1
    private var _driver: (any GlobalPauseDriver)?

    public init(storage: Storage = .dataDir()) {
        self.storage = storage
        self.ids = Set(storage.load())
    }

    /// The set a play would revive right now.
    public var paused: Set<String> { lock.withLock { ids } }

    /// True while a pause is in effect — non-empty *is* the paused state.
    public var isPaused: Bool { lock.withLock { !ids.isEmpty } }

    /// Add the sessions a pause just slept.
    ///
    /// Union, not assignment: pausing again after a partial play (some rows woken by
    /// hand) must not drop the ones still asleep from the set.
    public func record<S: Sequence>(_ slept: S) where S.Element == String {
        mutate { $0.formUnion(slept) }
    }

    /// Read the set and clear it in one step, so a play cannot revive a set the next
    /// pause has already started adding to.
    @discardableResult
    public func take() -> Set<String> {
        var taken: Set<String> = []
        mutate { taken = $0; $0 = [] }
        return taken
    }

    /// Who actually sleeps and wakes the sessions. Installed once per launch: the
    /// core installs one over its own registry so a headless server can serve a
    /// remote pause on its own, and the desktop replaces it with the model's, so a
    /// pause from the phone runs the exact code the toolbar button runs rather than
    /// a second implementation of the same rule.
    public var driver: (any GlobalPauseDriver)? {
        get { lock.withLock { _driver } }
        set { lock.withLock { _driver = newValue } }
    }

    /// Watch the set. Called on every change, never on subscribe — a caller that
    /// needs the current value reads `paused`. Returns a cancel handle.
    @discardableResult
    public func onChange(_ listener: @escaping @Sendable (Set<String>) -> Void) -> () -> Void {
        let token = lock.withLock { () -> Int in
            let t = nextToken
            nextToken += 1
            listeners[t] = listener
            return t
        }
        return { [weak self] in _ = self?.lock.withLock { self?.listeners.removeValue(forKey: token) } }
    }

    private func mutate(_ change: (inout Set<String>) -> Void) {
        let (after, fire): (Set<String>, [@Sendable (Set<String>) -> Void]) = lock.withLock {
            let before = ids
            change(&ids)
            guard ids != before else { return (ids, []) }
            storage.save(Array(ids))
            return (ids, Array(listeners.values))
        }
        for listener in fire { listener(after) }
    }
}

/// Whoever performs a global pause for this launch. Two implementations: the
/// registry-backed one a core installs (so a headless server answers a remote
/// pause), and the desktop model's (so the phone and the toolbar button are one
/// code path when the app is up).
public protocol GlobalPauseDriver: AnyObject, Sendable {
    /// Sleep every live agent session and record them in the book. Returns how many.
    @discardableResult
    func pauseAll() async -> Int
    /// Revive exactly the recorded set and clear it.
    func resumeAll() async
}

/// Lane bounds for a global play, shared by both drivers.
///
/// Each revival is a real `--resume` process, so the lane count is what bounds the
/// RAM and pty burst of a play after a big pause — the same bound the launch sweep
/// applies for the same reason.
public enum GlobalResume {
    public static let lanes = 4
    public static let gapMs = 150
}

/// Lock-guarded box behind `Storage.memory()`.
private final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func read() -> [String] { lock.withLock { value } }
    func write(_ v: [String]) { lock.withLock { value = v } }
}
