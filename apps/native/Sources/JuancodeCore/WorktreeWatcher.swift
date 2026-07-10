import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Live change awareness for a session's worktree, so the Changes panel (and,
/// later, a file-tree sidebar / Quick Open index) reflects edits the moment they
/// land — the agent mid-turn, an embedded editor, or the user externally — instead
/// of only on a busy→idle activity edge or a manual Refresh.
///
/// A `WorktreeWatcher` owns one macOS FSEvents stream over a single directory on a
/// dedicated dispatch queue. Raw filesystem events are coalesced (the FSEvents
/// latency window) and debounced (a cancellable work item that resets on each
/// burst), so a flurry of writes — a `git checkout`, an `npm install` churning
/// `node_modules`, the agent rewriting a dozen files — collapses into a single
/// change callback ~half a second after the tree settles. Idle CPU is zero: the
/// stream is kernel-backed and the debounce work item only exists while events
/// flow.
///
/// Events under `.git/` are dropped except `HEAD` and `index` — a branch switch or
/// a staging change alters the diff, but object/pack/log churn does not, and
/// watching it would just re-shell `git` for no visible change.
///
/// `@unchecked Sendable`: the FSEvents callback fires on `queue`; `stream` is
/// set once in `init` and cleared once in `stop`; `pending` is only touched on
/// `queue`. Mutation is guarded by `lock` where it can race a teardown. The stream
/// holds a *retained* reference to the watcher (via the context retain/release),
/// so a callback in flight can never touch a freed watcher; `stop` invalidates the
/// stream, which drops that reference.
public final class WorktreeWatcher: @unchecked Sendable {
    private let path: String
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// Start watching `path` recursively. `onChange` fires on the watcher's queue,
    /// coalesced + debounced. Fails (returns nil) if the FSEvents stream can't be
    /// created or started — the caller falls back to pull-based refresh.
    public init?(
        path: String,
        debounceMs: Int = 500,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.path = path
        self.debounce = .milliseconds(debounceMs)
        self.onChange = onChange
        self.queue = DispatchQueue(label: "juancode.worktree-watcher", qos: .utility)

        // The stream owns a +1 on the watcher; `worktreeContextRelease` drops it when
        // the stream is deallocated, so a callback in flight always sees a live self.
        let retained = Unmanaged.passRetained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0, info: retained,
            retain: nil, release: worktreeContextRelease, copyDescription: nil)
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer)
        // A short latency coalesces at the source; our own debounce does the rest.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, worktreeEventCallback, &ctx,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, flags)
        else {
            Unmanaged<WorktreeWatcher>.fromOpaque(retained).release()
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Invalidate + Release deallocates the stream, which invokes the context
            // release and drops the retained self — no extra balancing needed here.
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Tear the stream down and drop any pending debounce. Idempotent.
    public func stop() {
        lock.withLock {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
        queue.async { [weak self] in
            self?.pending?.cancel()
            self?.pending = nil
        }
    }

    deinit { stop() }

    /// Called on `queue` from the C callback. Drops irrelevant events, then
    /// (re)arms the debounce so `onChange` fires once the burst settles.
    fileprivate func handleEvents(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let relevant = events.contains { ev in
            // FSEvents dropped per-file detail under heavy churn — re-diff to be safe.
            if ev.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                return true
            }
            return WorktreeWatcher.isRelevantPath(ev.path, root: path)
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Whether a single changed path under `root` should trigger a diff refresh.
    /// The bare watched directory is ignored — FSEvents reports every ancestor
    /// directory of a change, so `.git`-only churn always surfaces the root too.
    /// Below the root, `.git/` is ignored except `HEAD` (branch switch) and `index`
    /// (staging), which move what the diff shows.
    static func isRelevantPath(_ path: String, root: String) -> Bool {
        let p = trimSlash(path)
        let r = trimSlash(root)
        if p == r { return false }
        guard p.hasPrefix(r + "/") else { return false }
        let rel = String(p.dropFirst(r.count + 1))
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let gitIdx = comps.firstIndex(of: ".git") else { return true }
        let after = comps[(gitIdx + 1)...]
        return after.elementsEqual(["HEAD"]) || after.elementsEqual(["index"])
    }

    private static func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") && s.count > 1 ? String(s.dropLast()) : s
    }
}

/// C-compatible FSEvents callback. Captures nothing (so it converts to the
/// function-pointer type); recovers the watcher from the context `info` pointer.
private func worktreeEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
    // With `kFSEventStreamCreateFlagUseCFTypes`, eventPaths is a CFArray of CFString.
    let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self)
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    events.reserveCapacity(count)
    for i in 0..<count {
        guard let path = cfPaths[i] as? String else { continue }
        events.append((path, flags[i]))
    }
    watcher.handleEvents(events)
}

/// Balances the `passRetained(self)` stored in the stream context — invoked by
/// CoreFoundation when the stream is deallocated.
private let worktreeContextRelease: CFAllocatorReleaseCallBack = { info in
    guard let info else { return }
    Unmanaged<WorktreeWatcher>.fromOpaque(info).release()
}

/// Shares one `WorktreeWatcher` per worktree path across every consumer in the
/// same checkout (several sessions can point at one worktree). Reference-counted:
/// the stream is created on the first `watch` for a path and torn down when the
/// last token is cancelled, so N open worktrees cost at most N idle streams.
public final class WorktreeWatcherRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextId = 0
    private var watchers: [String: WorktreeWatcher] = [:]
    private var subscribers: [String: [Int: @Sendable () -> Void]] = [:]

    public init() {}

    /// Subscribe to changes in `path`'s worktree. `onChange` fires (coalesced +
    /// debounced) whenever the tree changes. Returns a token whose `cancel` (or
    /// deallocation) releases the subscription; the shared stream is torn down when
    /// the last subscriber for that path goes away. Returns nil if the underlying
    /// stream can't be created.
    public func watch(
        path: String,
        onChange: @escaping @Sendable () -> Void
    ) -> WorktreeWatchToken? {
        let key = Self.canonical(path)
        return lock.withLock {
            let id = nextId
            nextId += 1
            if watchers[key] == nil {
                guard let watcher = WorktreeWatcher(path: key, onChange: { [weak self] in
                    self?.fanOut(key)
                }) else { return nil }
                watchers[key] = watcher
            }
            subscribers[key, default: [:]][id] = onChange
            return WorktreeWatchToken(registry: self, key: key, id: id)
        }
    }

    /// Number of live FSEvents streams (one per watched worktree path). For tests.
    public var activeStreamCount: Int { lock.withLock { watchers.count } }

    private func fanOut(_ key: String) {
        let handlers = lock.withLock { subscribers[key]?.values.map { $0 } ?? [] }
        for handler in handlers { handler() }
    }

    fileprivate func release(key: String, id: Int) {
        lock.withLock {
            subscribers[key]?.removeValue(forKey: id)
            if subscribers[key]?.isEmpty ?? false {
                subscribers.removeValue(forKey: key)
                watchers.removeValue(forKey: key)?.stop()
            }
        }
    }

    /// Canonicalize a path so two sessions in the same checkout share one stream,
    /// even if one was handed a symlinked or `..`-laden cwd. `realpath` fully
    /// resolves symlinks (including macOS's `/var` → `/private/var`), matching the
    /// resolved paths FSEvents reports — a plain `resolvingSymlinksInPath` leaves
    /// `/var` alone and would never prefix-match the stream's events.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Handle to one worktree subscription. Cancelling it (explicitly or by letting it
/// deallocate) releases the subscription and, if it was the last for that path,
/// tears down the shared stream.
public final class WorktreeWatchToken: @unchecked Sendable {
    private weak var registry: WorktreeWatcherRegistry?
    private let key: String
    private let id: Int
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(registry: WorktreeWatcherRegistry, key: String, id: Int) {
        self.registry = registry
        self.key = key
        self.id = id
    }

    public func cancel() {
        let already: Bool = lock.withLock {
            if cancelled { return true }
            cancelled = true
            return false
        }
        if already { return }
        registry?.release(key: key, id: id)
    }

    deinit { cancel() }
}
