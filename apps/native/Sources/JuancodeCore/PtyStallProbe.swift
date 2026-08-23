import Darwin
import Foundation

/// Diagnostic for a pty that produces no first frame.
///
/// Off unless `JUANCODE_PTY_PROBE` names a file to append to, so it costs a single
/// env lookup in production. When on, every `PtyProcess` registers at spawn and
/// deregisters on its first read; a shared watchdog then reports each pty that is
/// still silent, with the facts that tell the candidate mechanisms apart:
///
/// - `avail`: bytes sitting unread in the master (`FIONREAD`). Non-zero with no read
///   event means the reader is starved, not the child.
/// - `comm` / `stat`: the child's command name and process state. A `comm` still equal
///   to the parent's means the child has not reached `execve` yet, so the stall is in
///   the fork-to-exec window, not in the CLI.
/// - `syscalls`: the child's cumulative unix syscall count, rising fast iff it is
///   grinding through the pre-exec fd-close loop.
/// - `queueLagMs`: how long a no-op block queued behind the read handler took to run.
///   Large or never-resolving means the serial queue is wedged and no read handler
///   could have run.
enum PtyStallProbe {
    private struct Entry {
        let pid: pid_t
        let fd: Int32
        let queue: DispatchQueue
        let spawnedAt: Double
        var pingSentAt: Double?
        var pingRanAt: Double?
        var lastReported: Double
    }

    private static let sink: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["JUANCODE_PTY_PROBE"],
              !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        h.seekToEndOfFile()
        return h
    }()

    /// Stored, not computed: `noteRead` is on the pty read path, so the off case
    /// must be one load and a branch.
    static let enabled: Bool = sink != nil

    private static let lock = NSLock()
    // Guarded by `lock`; `nonisolated(unsafe)` because the lock, not the
    // compiler, is the invariant.
    nonisolated(unsafe) private static var live: [pid_t: Entry] = [:]
    private static let probeQueue = DispatchQueue(label: "juancode.pty.probe")
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?
    /// This process's own command name, so a child that has not exec'd is obvious.
    private static let ownComm = comm(of: getpid()) ?? "?"

    static func register(pid: pid_t, fd: Int32, queue: DispatchQueue) {
        guard enabled else { return }
        let now = monotonic()
        lock.withLock {
            live[pid] = Entry(pid: pid, fd: fd, queue: queue, spawnedAt: now, lastReported: now)
        }
        emit("spawn pid=\(pid) fd=\(fd)")
        armWatchdog()
    }

    /// Called on every read, not just the first: the first one deregisters the pty,
    /// so the rest cost one branch.
    static func noteRead(pid: pid_t, bytes: Int) {
        guard enabled else { return }
        let entry = lock.withLock { live.removeValue(forKey: pid) }
        guard let entry else { return }
        emit("firstRead pid=\(pid) afterMs=\(ms(monotonic() - entry.spawnedAt)) bytes=\(bytes)")
    }

    static func gone(pid: pid_t, why: String) {
        guard enabled else { return }
        let entry = lock.withLock { live.removeValue(forKey: pid) }
        guard let entry else { return }
        emit("gone pid=\(pid) why=\(why) silentForMs=\(ms(monotonic() - entry.spawnedAt))")
    }

    private static func armWatchdog() {
        lock.withLock {
            guard watchdog == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: probeQueue)
            t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            t.setEventHandler { tick() }
            watchdog = t
            t.resume()
        }
    }

    private static func tick() {
        let now = monotonic()
        let entries = lock.withLock { Array(live.values) }
        for e in entries {
            let silentMs = ms(now - e.spawnedAt)
            guard silentMs >= 1_500, now - e.lastReported >= 1.0 else { continue }
            lock.withLock { live[e.pid]?.lastReported = now }

            let alive = kill(e.pid, 0) == 0 || errno == EPERM
            var avail: Int32 = -1
            // FIONREAD: the macro is _IOR('f', 127, int), which Swift can't import.
            _ = ioctl(e.fd, UInt(0x4004_667F), &avail)
            let childComm = comm(of: e.pid) ?? "-"
            let info = task(of: e.pid)
            let lag = queueLag(e, now: now)
            emit("silent pid=\(e.pid) fd=\(e.fd) forMs=\(silentMs) alive=\(alive) "
                + "avail=\(avail) comm=\(childComm) preExec=\(childComm == ownComm) "
                + "stat=\(procStat(of: e.pid)) syscalls=\(info.syscalls) threads=\(info.threads) "
                + "cpuUs=\(info.cpuUs) running=\(info.running) csw=\(info.csw) "
                + "faults=\(info.faults) pageins=\(info.pageins) queueLagMs=\(lag)")
        }
    }

    /// Round-trip a no-op through the pty's serial queue. Reported negative while a
    /// ping is still outstanding, which is itself the signal: a lag that never
    /// resolves means the queue never ran anything.
    private static func queueLag(_ e: Entry, now: Double) -> Int {
        if let sent = e.pingSentAt, e.pingRanAt == nil { return -ms(now - sent) }
        let pid = e.pid
        let previous: Int
        if let sent = e.pingSentAt, let ran = e.pingRanAt { previous = ms(ran - sent) } else { previous = -1 }
        lock.withLock {
            live[pid]?.pingSentAt = now
            live[pid]?.pingRanAt = nil
        }
        e.queue.async {
            let at = monotonic()
            lock.withLock { live[pid]?.pingRanAt = at }
        }
        return previous
    }

    private static func emit(_ line: String) {
        guard let sink else { return }
        let stamp = String(format: "%.3f", monotonic())
        sink.write(Data("\(stamp) \(line)\n".utf8))
    }

    private static func monotonic() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private static func ms(_ seconds: Double) -> Int { Int(seconds * 1000) }

    private static func kinfo(of pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func comm(of pid: pid_t) -> String? {
        guard var info = kinfo(of: pid) else { return nil }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func procStat(of pid: pid_t) -> String {
        guard let info = kinfo(of: pid) else { return "gone" }
        switch Int32(info.kp_proc.p_stat) {
        case 1: return "idle"
        case 2: return "run"
        case 3: return "sleep"
        case 4: return "stop"
        case 5: return "zombie"
        default: return "s\(info.kp_proc.p_stat)"
        }
    }

    private struct TaskFacts {
        var syscalls: Int64 = -1
        var threads: Int32 = -1
        var cpuUs: Int64 = -1
        var running: Int32 = -1
        var csw: Int32 = -1
        var faults: Int32 = -1
        var pageins: Int32 = -1
    }

    private static func task(of pid: pid_t) -> TaskFacts {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) > 0 else { return TaskFacts() }
        return TaskFacts(
            syscalls: Int64(info.pti_syscalls_unix),
            threads: Int32(info.pti_threadnum),
            cpuUs: Int64((info.pti_total_user + info.pti_total_system) / 1_000),
            running: Int32(info.pti_numrunning),
            csw: Int32(info.pti_csw),
            faults: Int32(info.pti_faults),
            pageins: Int32(info.pti_pageins))
    }
}
