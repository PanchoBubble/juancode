import Darwin
import Foundation
import JuancodeCore

/// Idle-session reaper (juancode-lgq): kills the CLI process tree of sessions
/// that have been verifiably idle for a sustained window, freeing the 300MB-1GB
/// each claude/codex tree (plus its MCP servers) holds, while keeping the session
/// tile visible as *dormant* — resumable on demand through the existing
/// `reviveSession` paths (remote attach/input, PR-tracker reactivation).
///
/// Three things are never reaped, whatever the signals say: a session that is
/// still running something (busy, waiting on a prompt, or holding an unresolved
/// `tool_use`), the pane the user has open, and the Oracle they are talking to —
/// the last two pushed in by the app via `setProtectedIds`.
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
    /// ms-since-epoch of the last pty *output* byte, and the total bytes this
    /// session has produced (`Session.lastOutputMs` / `outputBytes`). Input is not
    /// a liveness signal for a dispatched agent — nobody types at one for hours —
    /// so the streak also watches what the pty *says*. Read as a rate, never as
    /// "any byte at all": a settled TUI still repaints itself, and keying on that
    /// is what defeated the old GUI idle sweep this reaper replaced.
    public var lastOutputMs: Int
    public var outputBytes: Int
    /// ms-since-epoch of the last moment the `ActivityDetector` classified this
    /// session as non-idle (`Session.lastBusyMs`). `activity` is a snapshot at
    /// sweep time; a whole turn can start and finish inside one 90s sweep gap and
    /// leave it reading idle. This is the same detector's memory of that turn — the
    /// one notion of "busy" in the codebase, not a second one.
    public var lastBusyMs: Int
    /// An agent tool call the CLI opened and hasn't resolved. Unlike `activity`,
    /// this is not capped by `ActivityDetector.toolHoldCapMs`: a delegated subagent
    /// or a long Bash run goes screen- and transcript-quiet, and past that 30-min
    /// cap the state falls back to `.idle` while the tool is still running — inside
    /// the default 60-min reap window. So the open call is its own hard veto.
    public var hasPendingToolUse: Bool
    /// Externally protected (the open pane, the active Oracle). Never reaped.
    public var isProtected: Bool

    public init(
        activity: SessionActivity,
        resumable: Bool,
        queueEmpty: Bool,
        lastInputMs: Int,
        descendantCount: Int,
        cpuTimeMs: Int,
        transcriptSizeBytes: Int?,
        lastOutputMs: Int = 0,
        outputBytes: Int = 0,
        lastBusyMs: Int = 0,
        hasPendingToolUse: Bool = false,
        isProtected: Bool = false
    ) {
        self.activity = activity
        self.resumable = resumable
        self.queueEmpty = queueEmpty
        self.lastInputMs = lastInputMs
        self.descendantCount = descendantCount
        self.cpuTimeMs = cpuTimeMs
        self.transcriptSizeBytes = transcriptSizeBytes
        self.lastOutputMs = lastOutputMs
        self.outputBytes = outputBytes
        self.lastBusyMs = lastBusyMs
        self.hasPendingToolUse = hasPendingToolUse
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
        /// When the *previous* sweep sampled, the tree CPU it saw, and the output
        /// byte total it saw. The CPU and output signals are rates between
        /// consecutive sweeps, so they need the last sample rather than only the
        /// idle-entry anchor.
        public var lastSampleMs: Int
        public var lastSampleCpuMs: Int
        public var lastSampleOutputBytes: Int
        /// How many consecutive sweeps have *observed* this session quiet, this one
        /// included. Elapsed time alone is a shared clock: one long stall, one
        /// clock jump or one settings change reads the same for every session at
        /// once, which is how 25 of them can be judged dormant in the same second.
        /// A count of independent observations cannot be shared that way — it is
        /// this session's own evidence, and it only grows one sweep at a time.
        public var quietSamples: Int

        public init(
            idleSinceMs: Int,
            descendantCount: Int,
            cpuTimeMs: Int,
            transcriptSizeBytes: Int? = nil,
            lastSampleMs: Int? = nil,
            lastSampleCpuMs: Int? = nil,
            lastSampleOutputBytes: Int = 0,
            quietSamples: Int = 1
        ) {
            self.idleSinceMs = idleSinceMs
            self.descendantCount = descendantCount
            self.cpuTimeMs = cpuTimeMs
            self.transcriptSizeBytes = transcriptSizeBytes
            self.lastSampleMs = lastSampleMs ?? idleSinceMs
            self.lastSampleCpuMs = lastSampleCpuMs ?? cpuTimeMs
            self.lastSampleOutputBytes = lastSampleOutputBytes
            self.quietSamples = quietSamples
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

    /// How fast the pty may produce output between two sweeps before the streak is
    /// disturbed, in bytes per second, with `defaultOutputFloorBytes` as the floor
    /// under it (same rate-plus-floor shape as the CPU signal).
    ///
    /// These are chosen bounds, not measurements: no numbers exist for how much a
    /// settled `claude`/`codex` TUI repaints while nobody is typing at it. They are
    /// deliberately loose, because the asymmetry this whole file is built on says a
    /// false "busy" only delays freeing RAM while a false "idle" kills work. 64KB
    /// inside one 90s sweep is roughly 700 B/s sustained — orders of magnitude more
    /// than a status line redrawing itself, and far less than any real stream (a
    /// build log, a test run, a tool dumping a file). Agent *token* streaming is
    /// slower than this bound and is deliberately not what it catches: the detector
    /// already classifies that as busy, and `lastBusyMs` carries it.
    public static let defaultOutputBusyBytesPerSec = 1_024
    public static let defaultOutputFloorBytes = 64 * 1024

    /// How many separate sweeps must observe a session quiet before it may be
    /// reaped, on top of the window. See `Baseline.quietSamples`.
    public static let defaultMinQuietSamples = 3

    /// The longest gap between two samples that still counts as an unbroken
    /// streak. Past it the reaper was not watching — a stalled sweep loop, a
    /// suspended machine, a clock jump — and time nobody observed is not evidence
    /// of dormancy, so the streak re-anchors and the session serves a fresh,
    /// observed window. With a 90s sweep this leaves ~6x headroom, so an ordinary
    /// late tick on a thrashing machine does not keep resetting everything.
    public static let defaultMaxSampleGapMs = 10 * 60 * 1000

    /// A fresh streak anchor from this sample: the moment the streak starts plus
    /// the tree shape, CPU, transcript size and output total at that moment. One
    /// observation of evidence, so `quietSamples` starts at 1.
    public static func anchor(_ sample: ReapSample, at nowMs: Int) -> Baseline {
        Baseline(
            idleSinceMs: nowMs,
            descendantCount: sample.descendantCount,
            cpuTimeMs: sample.cpuTimeMs,
            transcriptSizeBytes: sample.transcriptSizeBytes,
            lastSampleMs: nowMs,
            lastSampleCpuMs: sample.cpuTimeMs,
            lastSampleOutputBytes: sample.outputBytes,
            quietSamples: 1
        )
    }

    /// The same streak, one observation older: the anchor is kept, the sample point
    /// moves to this sweep (the CPU and output signals are sweep-to-sweep rates)
    /// and the evidence count grows by one.
    public static func advance(_ base: Baseline, with sample: ReapSample, at nowMs: Int) -> Baseline {
        var next = base
        next.lastSampleMs = nowMs
        next.lastSampleCpuMs = sample.cpuTimeMs
        next.lastSampleOutputBytes = sample.outputBytes
        next.quietSamples = base.quietSamples + 1
        return next
    }

    /// Evaluate one session against its tracked streak. `baseline` is what the
    /// previous sweep returned in `.holding` (nil when untracked).
    public static func evaluate(
        _ sample: ReapSample,
        baseline: Baseline?,
        nowMs: Int,
        windowMs: Int,
        cpuBusyPermille: Int = defaultCpuBusyPermille,
        cpuFloorMs: Int = defaultCpuFloorMs,
        outputBusyBytesPerSec: Int = defaultOutputBusyBytesPerSec,
        outputFloorBytes: Int = defaultOutputFloorBytes,
        minQuietSamples: Int = defaultMinQuietSamples,
        maxSampleGapMs: Int = defaultMaxSampleGapMs
    ) -> Verdict {
        guard windowMs > 0 else { return .notIdle } // reaping disabled
        // Hard resets: the detector says work (or a prompt) is pending, a tool call
        // is still open, a queued message is about to be delivered, or the session
        // is protected.
        guard sample.activity == .idle, !sample.hasPendingToolUse,
              sample.queueEmpty, !sample.isProtected
        else {
            return .notIdle
        }

        let fresh = anchor(sample, at: nowMs)
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
        // Output as a rate, for the same reason as CPU and with the same floor:
        // what the pty says is liveness for a session nobody types at, but a
        // repainting TUI must not be able to hold a session alive forever.
        let outputDelta = sample.outputBytes - base.lastSampleOutputBytes
        let outputMoved = outputDelta >= outputFloorBytes
            && outputDelta * 1_000 > intervalMs * outputBusyBytesPerSec
        let typedSinceIdle = sample.lastInputMs > base.idleSinceMs
        // The detector's memory of the streak: a turn that ran and finished between
        // two sweeps leaves `activity` idle but moves this.
        let workedSinceIdle = sample.lastBusyMs > base.idleSinceMs
        // Nobody was watching for `intervalMs`, so nothing was verified in it.
        let unobservedGap = intervalMs > maxSampleGapMs
        if treeChanged || cpuMoved || transcriptGrew || outputMoved
            || typedSinceIdle || workedSinceIdle || unobservedGap {
            return .holding(fresh)
        }

        // Streak intact: reap only once the whole window has been served, the
        // last keystroke is older than the window, and a resume is possible.
        // The sample point advances even while holding, so the next sweep's rate
        // is measured against this sweep rather than against idle-entry.
        let held = advance(base, with: sample, at: nowMs)
        guard nowMs - base.idleSinceMs >= windowMs,
              nowMs - sample.lastInputMs >= windowMs,
              held.quietSamples >= minQuietSamples,
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
    /// `(sessionId) -> never reap right now`. Defaults to never-protected: the app
    /// declares the open pane and the active Oracle through
    /// `SessionReaper.setProtectedIds` instead, since that state lives on the main
    /// actor. This seam stays for tests and other embedders.
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
    /// Hard ceiling on how many sessions one sweep may put to sleep, idle reaps and
    /// cap evictions together. A sweep that wants more takes the most-dormant ones
    /// and leaves the rest holding their streaks for the next tick, so reclaiming a
    /// backlog is a visible trickle (one every 90s) instead of a batch — and no
    /// single mistaken threshold can take the machine's whole session set with it.
    private let maxSleepsPerSweep: Int
    /// Where the audit trail goes: one `dormant` line per kill carrying the sample
    /// that justified it, plus one `reap_sweep` summary per sweep.
    private let log: SessionActivityLogging

    /// Tracked idle streaks by session id; entries drop whenever a session stops
    /// being idle (or stops existing).
    private var baselines: [String: SessionReapPolicy.Baseline] = [:]
    /// Sessions the UI declares off-limits right now: the pane you have open and
    /// the active Oracle. Pushed by the app (`setProtectedIds`) rather than probed,
    /// because the selection lives on the main actor and the sweep does not.
    private var protectedIds: Set<String> = []
    private var loop: Task<Void, Never>?

    public init(
        registry: SessionRegistry,
        messageQueue: MessageQueue,
        probes: SessionReaperProbes = .live(),
        windowMs: Int = Config.reapIdleMinutes * 60_000,
        maxLive: Int = Config.maxLiveSessions,
        cpuBusyPermille: Int = SessionReapPolicy.defaultCpuBusyPermille,
        sweepInterval: Duration = .seconds(90),
        maxSleepsPerSweep: Int = 3,
        log: SessionActivityLogging = NoopSessionActivityLog()
    ) {
        self.registry = registry
        self.messageQueue = messageQueue
        self.probes = probes
        self.windowMs = windowMs
        self.maxLive = maxLive
        self.cpuBusyPermille = cpuBusyPermille
        self.sweepInterval = sweepInterval
        self.maxSleepsPerSweep = max(1, maxSleepsPerSweep)
        self.log = log
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

    /// Replace the set of sessions that must never be slept — neither by the idle
    /// window nor by the live-session cap. The app pushes the pane you have open
    /// and the active Oracle: sleeping either one is visible work vanishing under
    /// you, which no amount of freed RAM pays for. Also drops any tracked streak
    /// for a newly protected session, so unprotecting it later starts a fresh
    /// window instead of reaping off a stale baseline.
    public func setProtectedIds(_ ids: Set<String>) {
        protectedIds = ids
        for id in ids { baselines[id] = nil }
    }

    /// Whether `id` is off-limits: the app's pushed set, or the injected probe
    /// (tests / other embedders).
    private func protected(_ id: String) -> Bool {
        protectedIds.contains(id) || probes.isProtected(id)
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

    /// One sweep over every live session: sample, evaluate, and put the eligible
    /// ones to sleep. Returns the slept session ids (for tests / logging).
    ///
    /// Three properties this loop owes the machine, learned the hard way:
    /// nothing dies without its own per-session evidence (`Baseline.quietSamples`);
    /// no sweep may take more than `maxSleepsPerSweep` sessions; and every kill is
    /// re-checked against live state at the instant of the kill, because the loop
    /// awaits a transcript stat per session and a verdict from the top of the loop
    /// can be seconds old by the time we act on it.
    @discardableResult
    public func sweepOnce() async -> [String] {
        let now = probes.nowMs()
        guard windowMs > 0 else {
            baselines = [:]
            // The cap is a separate guarantee from the idle window: turning
            // auto-sleep off must not let the machine accumulate without bound.
            let capped = sleepSurplus(nowMs: now, budget: maxSleepsPerSweep)
            logSweep(live: registry.all().filter(\.isRunning).count,
                     eligible: 0, reaped: 0, capSlept: capped.count, deferred: 0)
            return capped
        }
        var next: [String: SessionReapPolicy.Baseline] = [:]
        var eligible: [(session: Session, sample: ReapSample, prior: SessionReapPolicy.Baseline?)] = []
        var live = 0
        for session in registry.all() where session.isRunning {
            live += 1
            let meta = session.meta
            // No live child pid (already exiting) — nothing to reap.
            guard let pid = session.childPid else { continue }
            var transcriptSize: Int?
            if let cliSessionId = meta.cliSessionId {
                transcriptSize = await probes.transcriptSizeBytes(meta.provider, cliSessionId)
            }
            let sample = self.sample(session, pid: pid, transcriptSizeBytes: transcriptSize)
            let prior = baselines[meta.id]
            switch SessionReapPolicy.evaluate(
                sample, baseline: prior,
                nowMs: now, windowMs: windowMs, cpuBusyPermille: cpuBusyPermille
            ) {
            case .notIdle:
                break // streak dropped
            case .holding(let baseline):
                next[meta.id] = baseline
            case .eligible:
                eligible.append((session, sample, prior))
            }
        }

        // Most-dormant first, so a capped sweep reclaims the stalest RAM and the
        // order is deterministic (id breaks ties) rather than registry-dependent.
        eligible.sort {
            (($0.prior?.idleSinceMs ?? now), $0.session.meta.id)
                < (($1.prior?.idleSinceMs ?? now), $1.session.meta.id)
        }
        var reaped: [String] = []
        var deferred = 0
        for (session, sample, prior) in eligible {
            let id = session.meta.id
            guard reaped.count < maxSleepsPerSweep else {
                // Over budget for this tick: keep the streak (it stays eligible) so
                // the next sweep takes it, and say so in the log.
                deferred += 1
                next[id] = prior.map { SessionReapPolicy.advance($0, with: sample, at: now) }
                    ?? SessionReapPolicy.anchor(sample, at: now)
                continue
            }
            // Re-read the volatile signals at the instant of the kill. Between the
            // verdict and here the session may have started a turn, opened a tool
            // call, or become the pane the user is looking at — and a stale
            // "eligible" is precisely how a focused, working session gets reaped.
            if let veto = killTimeVeto(session) {
                log.log("reap_skipped", sessionId: id, project: session.meta.cwd,
                        fields: ["veto": veto, "waitedMs": "\(max(0, probes.nowMs() - now))"])
                next[id] = SessionReapPolicy.anchor(sample, at: now)
                continue
            }
            session.markDormant(
                reason: .idleReap,
                audit: audit(sample: sample, baseline: prior, now: now))
            session.kill()
            reaped.append(id)
        }
        baselines = next
        let capped = sleepSurplus(nowMs: now, budget: maxSleepsPerSweep - reaped.count,
                                  alreadyReaped: Set(reaped))
        logSweep(live: live, eligible: eligible.count, reaped: reaped.count,
                 capSlept: capped.count, deferred: deferred)
        return reaped + capped
    }

    /// Everything about one session the policy reads. Kept in one place so the
    /// sweep's decision and its kill-time re-check cannot drift apart.
    private func sample(
        _ session: Session, pid: pid_t, transcriptSizeBytes: Int?
    ) -> ReapSample {
        let meta = session.meta
        return ReapSample(
            activity: session.activity,
            resumable: meta.cliSessionId != nil,
            queueEmpty: messageQueue.peek(meta.id) == nil,
            lastInputMs: session.lastInputMs,
            descendantCount: probes.descendantCount(pid),
            cpuTimeMs: probes.treeCpuTimeMs(pid),
            transcriptSizeBytes: transcriptSizeBytes,
            lastOutputMs: session.lastOutputMs,
            outputBytes: session.outputBytes,
            lastBusyMs: session.lastBusyMs,
            hasPendingToolUse: session.hasPendingToolUse,
            isProtected: protected(meta.id)
        )
    }

    /// Why this session must not be killed right now, or nil when it may be. The
    /// cheap, non-awaiting half of the policy, re-evaluated immediately before the
    /// kill; the returned string is the log's `veto` field.
    private func killTimeVeto(_ session: Session) -> String? {
        let meta = session.meta
        if !session.isRunning { return "exited" }
        if protected(meta.id) { return "protected" }
        if session.activity != .idle { return session.activity.rawValue }
        if session.hasPendingToolUse { return "tool_open" }
        if messageQueue.peek(meta.id) != nil { return "queued" }
        if meta.cliSessionId == nil { return "unresumable" }
        return nil
    }

    /// The evidence behind one kill, as flat log fields: how long the streak ran,
    /// how many sweeps observed it, and where each signal stood. Reading one of
    /// these lines should answer "why did this die" without a forensic session.
    private func audit(
        sample: ReapSample, baseline: SessionReapPolicy.Baseline?, now: Int
    ) -> [String: String] {
        var fields: [String: String] = [
            "activity": sample.activity.rawValue,
            "idleMs": "\(now - (baseline?.idleSinceMs ?? now))",
            "windowMs": "\(windowMs)",
            "samples": "\(baseline?.quietSamples ?? 0)",
            "inputAgeMs": "\(now - sample.lastInputMs)",
            "outputAgeMs": "\(now - sample.lastOutputMs)",
            "busyAgeMs": sample.lastBusyMs > 0 ? "\(now - sample.lastBusyMs)" : "never",
            "descendants": "\(sample.descendantCount)",
            "cpuMs": "\(sample.cpuTimeMs)",
            "outputBytes": "\(sample.outputBytes)",
            "toolOpen": "\(sample.hasPendingToolUse)",
            "protected": "\(sample.isProtected)",
        ]
        if let base = baseline {
            let interval = max(1, now - base.lastSampleMs)
            fields["cpuPermille"] = "\((sample.cpuTimeMs - base.lastSampleCpuMs) * 1_000 / interval)"
            fields["outputDeltaBytes"] = "\(sample.outputBytes - base.lastSampleOutputBytes)"
        }
        if let size = sample.transcriptSizeBytes { fields["transcriptBytes"] = "\(size)" }
        return fields
    }

    /// One line per sweep, whether or not anything died: the denominator that makes
    /// the `dormant` lines readable (how many were live, how many the policy judged
    /// eligible, how many the per-sweep budget held back).
    private func logSweep(live: Int, eligible: Int, reaped: Int, capSlept: Int, deferred: Int) {
        guard live > 0 else { return }
        log.log("reap_sweep", sessionId: "-", project: "", fields: [
            "live": "\(live)", "eligible": "\(eligible)", "reaped": "\(reaped)",
            "capSlept": "\(capSlept)", "deferred": "\(deferred)",
            "windowMs": "\(windowMs)", "maxLive": "\(maxLive)",
            "budget": "\(maxSleepsPerSweep)",
        ])
    }

    /// Enforce the live-session ceiling: sleep the least-recently-active sessions
    /// that are safe to sleep until at most `maxLive` remain, at most `budget` of
    /// them in this sweep. Independent of the idle streak — a session that keeps
    /// getting touched never serves a full window, but still holds a whole CLI
    /// process tree.
    private func sleepSurplus(
        nowMs: Int, budget: Int, alreadyReaped: Set<String> = []
    ) -> [String] {
        guard maxLive > 0, budget > 0 else { return [] }
        let live = registry.all().filter { $0.isRunning && !alreadyReaped.contains($0.meta.id) }
        let candidates = live.map { session -> SessionCapPolicy.Candidate in
            let meta = session.meta
            return .init(id: meta.id,
                         lastActiveMs: max(meta.updatedAt, session.lastInputMs),
                         sleepable: killTimeVeto(session) == nil)
        }
        let surplus = SessionCapPolicy.surplus(candidates, maxLive: maxLive)
        guard !surplus.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.meta.id, $0) })
        var slept: [String] = []
        for id in surplus {
            guard slept.count < budget else { break }
            guard let session = byId[id] else { continue }
            // Same instant-of-the-kill re-check as the idle path: the LRU order was
            // computed before this loop started.
            if let veto = killTimeVeto(session) {
                log.log("cap_skipped", sessionId: id, project: session.meta.cwd,
                        fields: ["veto": veto])
                continue
            }
            session.markDormant(reason: .liveCap, audit: [
                "activity": session.activity.rawValue,
                "maxLive": "\(maxLive)",
                "liveCount": "\(live.count)",
                "lastActiveMs": "\(nowMs - max(session.meta.updatedAt, session.lastInputMs))",
            ])
            session.kill()
            slept.append(id)
            // Its streak is meaningless now the pty is gone.
            baselines[id] = nil
        }
        return slept
    }
}
