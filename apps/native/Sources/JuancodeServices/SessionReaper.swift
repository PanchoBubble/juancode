import Darwin
import Foundation
import JuancodeCore

/// Idle-session reaper (juancode-lgq): kills the CLI process tree of sessions
/// that have been verifiably idle for a sustained window, freeing the 300MB-1GB
/// each claude/codex tree (plus its MCP servers) holds, while keeping the session
/// tile visible as *dormant* — resumable on demand through the existing
/// `reviveSession` paths (remote attach/input, PR-tracker reactivation).
///
/// The `ActivityDetector` alone isn't trusted: it reads the screen and the
/// transcript, both of which can look quiet mid-work (long thinking, delegation
/// gaps). So eligibility stacks *independent* signals, sampled every sweep, and a
/// session is reaped only when ALL hold across the whole window. The asymmetry is
/// deliberate — a false "busy" merely delays freeing RAM, a false "idle" kills
/// real work — so any single disturbed signal restarts the streak.
///
/// The decision rule itself (`SessionReapPolicy`) is pure; the OS probes (process
/// tree, CPU, transcript size) are injected seams so tests pin them.

// MARK: - pure eligibility policy

/// One session's observable state at a sweep tick, assembled by the reaper from
/// the live `Session`, the message queue, and the OS probes.
public struct ReapSample: Sendable, Equatable {
    /// Current `ActivityDetector` state. Anything but `.idle` resets the streak —
    /// including `.waitingInput`: a pending permission menu isn't in the
    /// transcript until answered, so killing there aborts the tool call and a
    /// resume won't re-render the prompt.
    public var activity: SessionActivity
    /// `meta.cliSessionId != nil`. Unresumable sessions are exempt from reaping
    /// (Codex discovers its id late) — killing one would lose the conversation.
    public var resumable: Bool
    /// Whether the session's outbound `MessageQueue` is empty. Queued messages
    /// mean deliveries are imminent; reaping would strand them.
    public var queueEmpty: Bool
    /// ms-since-epoch of the last input written to the pty (`Session.lastInputMs`)
    /// — protects a half-typed, unsubmitted prompt no other signal can see.
    public var lastInputMs: Int
    /// Live descendant processes of the pty child (Bash tools, spawned subagents,
    /// MCP servers). Compared against the count captured at idle-entry: any change
    /// means the tree is (or was) doing something.
    public var descendantCount: Int
    /// Cumulative CPU time of the whole process tree, ms. Compared as a *rate*
    /// against the previous sweep, not as an absolute total since idle-entry: an
    /// idle CLI is not a quiet process (see `defaultCpuBusyPermille`).
    public var cpuTimeMs: Int
    /// Size in bytes of the session's CLI transcript, nil when the file can't be
    /// located — treated as "no evidence of activity"; the process-tree and CPU
    /// signals still guard. Size rather than mtime: the transcript is append-only,
    /// so growth is the thing that means the agent produced something, while the
    /// mtime also moves on flushes that add no records.
    public var transcriptSizeBytes: Int?
    /// Externally protected (e.g. the focused pane). Never reaped.
    public var isProtected: Bool

    public init(
        activity: SessionActivity,
        resumable: Bool,
        queueEmpty: Bool,
        lastInputMs: Int,
        descendantCount: Int,
        cpuTimeMs: Int,
        transcriptSizeBytes: Int?,
        isProtected: Bool = false
    ) {
        self.activity = activity
        self.resumable = resumable
        self.queueEmpty = queueEmpty
        self.lastInputMs = lastInputMs
        self.descendantCount = descendantCount
        self.cpuTimeMs = cpuTimeMs
        self.transcriptSizeBytes = transcriptSizeBytes
        self.isProtected = isProtected
    }
}

/// The reap-eligibility state machine. Pure and clock-injected so the brittle
/// part — when it is safe to kill — is unit-testable without ptys or timers.
public enum SessionReapPolicy {
    /// The idle streak's anchor, captured when a session is first seen idle (and
    /// re-captured whenever any OS signal is disturbed): the moment the streak
    /// started plus the process-tree shape and CPU total at that moment.
    public struct Baseline: Sendable, Equatable {
        public var idleSinceMs: Int
        public var descendantCount: Int
        public var cpuTimeMs: Int
        /// Transcript size at idle-entry; growth past it means the agent produced
        /// records. Nil when the transcript couldn't be located.
        public var transcriptSizeBytes: Int?
        /// When the *previous* sweep sampled, and the tree CPU it saw. The CPU
        /// signal is a rate between consecutive sweeps, so it needs the last
        /// sample rather than only the idle-entry anchor.
        public var lastSampleMs: Int
        public var lastSampleCpuMs: Int

        public init(
            idleSinceMs: Int,
            descendantCount: Int,
            cpuTimeMs: Int,
            transcriptSizeBytes: Int? = nil,
            lastSampleMs: Int? = nil,
            lastSampleCpuMs: Int? = nil
        ) {
            self.idleSinceMs = idleSinceMs
            self.descendantCount = descendantCount
            self.cpuTimeMs = cpuTimeMs
            self.transcriptSizeBytes = transcriptSizeBytes
            self.lastSampleMs = lastSampleMs ?? idleSinceMs
            self.lastSampleCpuMs = lastSampleCpuMs ?? cpuTimeMs
        }
    }

    /// The sweep's decision for one session.
    public enum Verdict: Sendable, Equatable {
        /// Not idle (busy / waiting for input / protected / queue pending) —
        /// drop any tracked streak.
        case notIdle
        /// Idle, but the window hasn't been served yet (or the session is
        /// unresumable / saw recent input). Carry `Baseline` to the next sweep —
        /// a *fresh* baseline when an OS signal was disturbed.
        case holding(Baseline)
        /// Verifiably idle across the whole window: safe to reap.
        case eligible
    }

    /// How fast the process tree may burn CPU between two sweeps before the streak
    /// is considered disturbed, in permille of one core. An idle CLI is NOT a quiet
    /// process: it keeps repainting its TUI, measured here at a median 5.8% of a
    /// core (p90 7.0%, max 10.9%) across 51 idle sessions over 5 minutes. The
    /// original rule — an absolute 5s of CPU accrued since idle-entry — was
    /// therefore unmeetable: 40 of those 51 blew past 5s within a *single* 90s
    /// sweep and 47 of 51 within any 60-min window, so the baseline re-anchored
    /// every sweep and no session ever became eligible. 400‰ (40% of a core)
    /// leaves ~4x headroom over idle repainting while still catching real local
    /// compute the detector missed.
    public static let defaultCpuBusyPermille = 400

    /// Floor under the rate check: a CPU delta this small is never "work",
    /// whatever the interval. Guards a sweep pair that lands milliseconds apart,
    /// where the rate divisor is tiny and any jitter would read as busy.
    public static let defaultCpuFloorMs = 2_000

    /// Evaluate one session against its tracked streak. `baseline` is what the
    /// previous sweep returned in `.holding` (nil when untracked).
    public static func evaluate(
        _ sample: ReapSample,
        baseline: Baseline?,
        nowMs: Int,
        windowMs: Int,
        cpuBusyPermille: Int = defaultCpuBusyPermille,
        cpuFloorMs: Int = defaultCpuFloorMs
    ) -> Verdict {
        guard windowMs > 0 else { return .notIdle } // reaping disabled
        // Hard resets: the detector says work (or a prompt) is pending, a queued
        // message is about to be delivered, or the session is protected.
        guard sample.activity == .idle, sample.queueEmpty, !sample.isProtected else {
            return .notIdle
        }

        let fresh = Baseline(
            idleSinceMs: nowMs,
            descendantCount: sample.descendantCount,
            cpuTimeMs: sample.cpuTimeMs,
            transcriptSizeBytes: sample.transcriptSizeBytes,
            lastSampleMs: nowMs,
            lastSampleCpuMs: sample.cpuTimeMs
        )
        guard let base = baseline else { return .holding(fresh) } // idle-entry

        // OS ground truth the detector can't fake. Any disturbance restarts the
        // streak from now, with the current tree shape / CPU as the new baseline.
        let treeChanged = sample.descendantCount != base.descendantCount
        // CPU as a rate since the previous sweep, not a total since idle-entry:
        // idle CLIs burn a steady few percent of a core forever, so any absolute
        // budget is spent by simply waiting. See `defaultCpuBusyPermille`.
        let intervalMs = max(1, nowMs - base.lastSampleMs)
        let cpuDelta = sample.cpuTimeMs - base.lastSampleCpuMs
        let cpuMoved = cpuDelta >= cpuFloorMs && cpuDelta * 1_000 > intervalMs * cpuBusyPermille
        // Append-only transcript: growth means the agent produced records. A bare
        // mtime bump does not — the file is also touched on flushes that add none.
        let transcriptGrew: Bool
        if let now = sample.transcriptSizeBytes, let then = base.transcriptSizeBytes {
            transcriptGrew = now > then
        } else {
            transcriptGrew = false
        }
        let typedSinceIdle = sample.lastInputMs > base.idleSinceMs
        if treeChanged || cpuMoved || transcriptGrew || typedSinceIdle {
            return .holding(fresh)
        }

        // Streak intact: reap only once the whole window has been served, the
        // last keystroke is older than the window, and a resume is possible.
        // The sample point advances even while holding, so the next sweep's rate
        // is measured against this sweep rather than against idle-entry.
        var held = base
        held.lastSampleMs = nowMs
        held.lastSampleCpuMs = sample.cpuTimeMs
        guard nowMs - base.idleSinceMs >= windowMs,
              nowMs - sample.lastInputMs >= windowMs,
              sample.resumable
        else { return .holding(held) }
        return .eligible
    }
}

/// The live-session cap (juancode: LRU sleep). The idle window alone doesn't bound
/// memory — a machine can accumulate dozens of sessions that are each *recently*
/// active and so never serve a full idle window, while every one of them holds a
/// full CLI process tree. Measured here: 47 concurrent `claude` sessions at a
/// median 290MB phys_footprint each — 12.4GB, with the machine 20GB into swap.
///
/// So past a ceiling the reaper also sleeps the least-recently-active sessions,
/// regardless of how long they've been idle. Only sessions that are safe to reap
/// anyway are candidates; busy ones count toward the total (they're holding the
/// RAM) but are never chosen.
public enum SessionCapPolicy {
    /// One live session's state for the cap decision.
    public struct Candidate: Sendable, Equatable {
        public var id: String
        /// Recency for the LRU order: the later of last output and last input.
        public var lastActiveMs: Int
        /// Safe to sleep right now — idle, resumable, nothing queued, unprotected.
        public var sleepable: Bool

        public init(id: String, lastActiveMs: Int, sleepable: Bool) {
            self.id = id
            self.lastActiveMs = lastActiveMs
            self.sleepable = sleepable
        }
    }

    /// Ids to sleep so at most `maxLive` sessions stay live, least-recently-active
    /// first. `maxLive <= 0` disables the cap. Never returns more than the number
    /// of sleepable candidates — an over-cap machine full of busy sessions simply
    /// stays over cap rather than killing work.
    public static func surplus(_ candidates: [Candidate], maxLive: Int) -> [String] {
        guard maxLive > 0, candidates.count > maxLive else { return [] }
        let overBy = candidates.count - maxLive
        return candidates
            .filter(\.sleepable)
            .sorted { ($0.lastActiveMs, $0.id) < ($1.lastActiveMs, $1.id) }
            .prefix(overBy)
            .map(\.id)
    }
}

// MARK: - OS probes

/// Walks live process trees via libproc. The pty child is its own session leader
/// (`forkpty`), so its descendants are exactly the CLI's helpers: MCP servers,
/// Bash tools, spawned subagents.
public enum ProcessTree {
    /// All live descendant pids of `pid` (children, grandchildren, …), excluding
    /// `pid` itself.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast() {
            let kids = children(of: next)
            result.append(contentsOf: kids)
            queue.append(contentsOf: kids)
        }
        return result
    }

    /// Direct children of `pid` via `proc_listchildpids`, growing the buffer if a
    /// burst of children fills it.
    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            let n = buf.withUnsafeMutableBytes { raw in
                proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
            }
            guard n >= 0 else { return [] }
            if Int(n) < capacity { return Array(buf[0..<Int(n)]) }
            capacity *= 2
        }
    }

    /// Cumulative CPU time (user + system) of `pid` in ms via `proc_pid_rusage`,
    /// or nil when the process is gone.
    public static func cpuTimeMs(of pid: pid_t) -> Int? {
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reb)
            }
        }
        guard rc == 0 else { return nil }
        // ri_*_time are in mach time units; convert to ns before ms.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let machTicks = info.ri_user_time &+ info.ri_system_time
        let ns = machTicks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return Int(ns / 1_000_000)
    }

    /// Cumulative CPU of `pid` plus all its live descendants, ms. Processes that
    /// vanish mid-walk contribute nothing — fine, since a vanished descendant also
    /// changes the descendant count and restarts the streak.
    public static func treeCpuTimeMs(of pid: pid_t) -> Int {
        ([pid] + descendants(of: pid)).reduce(0) { $0 + (cpuTimeMs(of: $1) ?? 0) }
    }
}

/// The reaper's injected seams: the clock, the process-tree probes, the transcript
/// size lookup, and the external protection check. `live()` wires the real OS.
public struct SessionReaperProbes: Sendable {
    public var nowMs: @Sendable () -> Int
    /// `(childPid) -> live descendant count` of the session's pty child.
    public var descendantCount: @Sendable (pid_t) -> Int
    /// `(childPid) -> cumulative CPU ms` of the whole process tree.
    public var treeCpuTimeMs: @Sendable (pid_t) -> Int
    /// `(provider, cliSessionId) -> transcript size in bytes`, nil when not found.
    public var transcriptSizeBytes: @Sendable (ProviderId, String) async -> Int?
    /// `(sessionId) -> never reap right now` (e.g. the focused pane). Defaults to
    /// never-protected; the last-keystroke window covers actively used sessions.
    public var isProtected: @Sendable (String) -> Bool

    public init(
        nowMs: @escaping @Sendable () -> Int = { JuancodeCore.nowMs() },
        descendantCount: @escaping @Sendable (pid_t) -> Int,
        treeCpuTimeMs: @escaping @Sendable (pid_t) -> Int,
        transcriptSizeBytes: @escaping @Sendable (ProviderId, String) async -> Int?,
        isProtected: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.nowMs = nowMs
        self.descendantCount = descendantCount
        self.treeCpuTimeMs = treeCpuTimeMs
        self.transcriptSizeBytes = transcriptSizeBytes
        self.isProtected = isProtected
    }

    /// Production probes: libproc process walking and the real transcript files
    /// (path resolution cached per cli session id — transcripts never move).
    public static func live() -> SessionReaperProbes {
        let paths = TranscriptPathCache()
        return SessionReaperProbes(
            descendantCount: { ProcessTree.descendants(of: $0).count },
            treeCpuTimeMs: { ProcessTree.treeCpuTimeMs(of: $0) },
            transcriptSizeBytes: { provider, cliSessionId in
                guard let file = await paths.resolve(provider, cliSessionId) else { return nil }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
                      let size = attrs[.size] as? NSNumber else { return nil }
                return size.intValue
            }
        )
    }
}

/// Caches `resolveTranscriptFile` results so each sweep stats a known path
/// instead of re-scanning the CLI's transcript directories.
/// `@unchecked Sendable`: the map is only touched under `lock`.
final class TranscriptPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: String] = [:]

    func resolve(_ provider: ProviderId, _ cliSessionId: String) async -> String? {
        if let cached = lock.withLock({ paths[cliSessionId] }) { return cached }
        guard let file = await resolveTranscriptFile(provider, cliSessionId) else { return nil }
        lock.withLock { paths[cliSessionId] = file }
        return file
    }
}

// MARK: - the reaper

/// Owns the sweep loop and the per-session idle streaks. One process-wide
/// instance lives on `AppState`, next to `PrTrackingEngine`.
///
/// This replaced the older GUI `autoCloseIdleMinutes` sweep, which keyed on
/// `lastOutputMs` — spinner or keepalive output defeated it, and it closed the
/// session outright. The reaper keys on verified idleness and leaves a dormant,
/// resumable tile. The Settings → Sessions idle window still drives it, through
/// `setIdleWindow`.
public actor SessionReaper {
    private let registry: SessionRegistry
    private let messageQueue: MessageQueue
    private let probes: SessionReaperProbes
    private var windowMs: Int
    private var maxLive: Int
    private let cpuBusyPermille: Int
    private let sweepInterval: Duration

    /// Tracked idle streaks by session id; entries drop whenever a session stops
    /// being idle (or stops existing).
    private var baselines: [String: SessionReapPolicy.Baseline] = [:]
    private var loop: Task<Void, Never>?

    public init(
        registry: SessionRegistry,
        messageQueue: MessageQueue,
        probes: SessionReaperProbes = .live(),
        windowMs: Int = Config.reapIdleMinutes * 60_000,
        maxLive: Int = Config.maxLiveSessions,
        cpuBusyPermille: Int = SessionReapPolicy.defaultCpuBusyPermille,
        sweepInterval: Duration = .seconds(90)
    ) {
        self.registry = registry
        self.messageQueue = messageQueue
        self.probes = probes
        self.windowMs = windowMs
        self.maxLive = maxLive
        self.cpuBusyPermille = cpuBusyPermille
        self.sweepInterval = sweepInterval
    }

    /// Change the idle window at runtime (the Settings → Sessions stepper).
    /// `minutes <= 0` disables reaping — sweeps become no-ops and any tracked
    /// streaks are dropped, so a later re-enable starts fresh instead of reaping
    /// off a stale baseline.
    public func setIdleWindow(minutes: Int) {
        windowMs = minutes * 60_000
    }

    /// Change the live-session ceiling at runtime. `<= 0` disables the cap.
    public func setMaxLive(_ count: Int) {
        maxLive = count
    }

    /// Start the periodic sweep. No-op when already running. Runs even while the
    /// window is disabled — each tick is then a cheap no-op — so `setIdleWindow`
    /// can enable/disable reaping without loop management.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, sweepInterval] in
            while !Task.isCancelled {
                await Nap.duration(sweepInterval)
                guard let self else { return }
                await self.sweepOnce()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One sweep over every live session: sample, evaluate, and reap the eligible
    /// ones. Returns the reaped session ids (for tests / logging).
    @discardableResult
    public func sweepOnce() async -> [String] {
        guard windowMs > 0 else {
            baselines = [:]
            // The cap is a separate guarantee from the idle window: turning
            // auto-sleep off must not let the machine accumulate without bound.
            return sleepSurplus(nowMs: probes.nowMs())
        }
        let now = probes.nowMs()
        var reaped: [String] = []
        var next: [String: SessionReapPolicy.Baseline] = [:]
        for session in registry.all() where session.isRunning {
            let meta = session.meta
            // No live child pid (already exiting) — nothing to reap.
            guard let pid = session.childPid else { continue }
            var transcriptSize: Int?
            if let cliSessionId = meta.cliSessionId {
                transcriptSize = await probes.transcriptSizeBytes(meta.provider, cliSessionId)
            }
            let sample = ReapSample(
                activity: session.activity,
                resumable: meta.cliSessionId != nil,
                queueEmpty: messageQueue.peek(meta.id) == nil,
                lastInputMs: session.lastInputMs,
                descendantCount: probes.descendantCount(pid),
                cpuTimeMs: probes.treeCpuTimeMs(pid),
                transcriptSizeBytes: transcriptSize,
                isProtected: probes.isProtected(meta.id)
            )
            switch SessionReapPolicy.evaluate(
                sample, baseline: baselines[meta.id],
                nowMs: now, windowMs: windowMs, cpuBusyPermille: cpuBusyPermille
            ) {
            case .notIdle:
                break // streak dropped
            case .holding(let baseline):
                next[meta.id] = baseline
            case .eligible:
                // Flag first so the exited row `handleExit` persists already reads
                // as dormant; scrollback + meta survive via the normal exit path.
                session.markDormant()
                session.kill()
                reaped.append(meta.id)
            }
        }
        baselines = next
        reaped.append(contentsOf: sleepSurplus(nowMs: now, alreadyReaped: Set(reaped)))
        return reaped
    }

    /// Enforce the live-session ceiling: sleep the least-recently-active sessions
    /// that are safe to sleep until at most `maxLive` remain. Independent of the
    /// idle streak — a session that keeps getting touched never serves a full
    /// window, but still holds a whole CLI process tree.
    private func sleepSurplus(nowMs: Int, alreadyReaped: Set<String> = []) -> [String] {
        guard maxLive > 0 else { return [] }
        let live = registry.all().filter { $0.isRunning && !alreadyReaped.contains($0.meta.id) }
        let candidates = live.map { session -> SessionCapPolicy.Candidate in
            let meta = session.meta
            let sleepable = session.activity == .idle
                && meta.cliSessionId != nil
                && messageQueue.peek(meta.id) == nil
                && !probes.isProtected(meta.id)
            return .init(id: meta.id,
                         lastActiveMs: max(meta.updatedAt, session.lastInputMs),
                         sleepable: sleepable)
        }
        let surplus = Set(SessionCapPolicy.surplus(candidates, maxLive: maxLive))
        guard !surplus.isEmpty else { return [] }
        for session in live where surplus.contains(session.meta.id) {
            session.markDormant()
            session.kill()
        }
        // Their streaks are meaningless now the pty is gone.
        for id in surplus { baselines[id] = nil }
        return Array(surplus)
    }
}
