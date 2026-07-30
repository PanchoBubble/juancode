import Foundation
import Darwin

/// One memory-heavy command going through the global `heavy` slot queue — either
/// holding a slot (`slot > 0`) or waiting in line.
///
/// The queue is a shared filesystem registry: `~/.claude/bin/heavy` writes one JSON
/// entry per job under `/tmp/claude-heavy-$UID/queue/<pid>.json`, then admits jobs in
/// (priority desc, enqueue time asc) order. Because ordering is read from those files
/// on every poll, rewriting an entry's `prio` moves it up or down the line — that's
/// what the Heavy Queue panel does.
public struct HeavyJob: Sendable, Identifiable, Equatable {
    /// The wrapper's pid — also the registry filename and the id we signal to cancel.
    public let pid: Int
    /// The actual command's pid, once it's running. The wrapper forwards SIGTERM to it.
    public let child: Int?
    /// Higher runs sooner. Default 0; `HEAVY_PRIO=n heavy …` or the panel sets others.
    public let prio: Int
    /// Epoch seconds when the job joined the queue.
    public let since: Int
    /// Epoch seconds when it got a slot and actually started; nil while waiting.
    public let started: Int?
    /// Slot index it holds, or 0 while waiting.
    public let slot: Int
    public let cmd: String
    public let cwd: String

    public var id: Int { pid }
    public var running: Bool { slot > 0 }
    /// Last path component of the working directory — the project label in the panel.
    public var project: String { (cwd as NSString).lastPathComponent }

    public init(pid: Int, child: Int? = nil, prio: Int = 0, since: Int = 0,
                started: Int? = nil, slot: Int = 0, cmd: String = "", cwd: String = "") {
        self.pid = pid
        self.child = child
        self.prio = prio
        self.since = since
        self.started = started
        self.slot = slot
        self.cmd = cmd
        self.cwd = cwd
    }
}

/// The whole queue at a moment: its capacity and the two ordered lists the panel draws.
public struct HeavyQueueSnapshot: Sendable, Equatable {
    public var slots: Int
    public var workerCap: Int
    public var running: [HeavyJob]
    public var waiting: [HeavyJob]

    public init(slots: Int = 1, workerCap: Int = 4,
                running: [HeavyJob] = [], waiting: [HeavyJob] = []) {
        self.slots = slots
        self.workerCap = workerCap
        self.running = running
        self.waiting = waiting
    }

    public var isEmpty: Bool { running.isEmpty && waiting.isEmpty }
    public var total: Int { running.count + waiting.count }
}

/// Reader/controller for the global heavy-command queue. Read-mostly: the only writes
/// are a job's priority (an atomic rewrite of its own entry) and a cancel (SIGTERM to
/// the wrapper, which takes its child down with it).
public struct HeavyQueue: Sendable {
    /// `/tmp/claude-heavy-$UID` — the lock root the wrapper uses.
    public let root: URL
    /// `~/.claude/heavy-queue.json` — slots + worker cap live here.
    public let configPath: URL
    /// Liveness probe, injectable for tests.
    let isAlive: @Sendable (Int) -> Bool
    /// Command line for a pid, for slots held by a wrapper with no registry entry
    /// (one started before the registry existed, or whose entry was lost).
    let commandForPid: @Sendable (Int) -> String?

    public static let shared = HeavyQueue()

    public init(root: URL? = nil, configPath: URL? = nil,
                isAlive: @escaping @Sendable (Int) -> Bool = HeavyQueue.pidIsAlive,
                commandForPid: @escaping @Sendable (Int) -> String? = HeavyQueue.psCommand) {
        self.root = root ?? URL(fileURLWithPath: "/tmp/claude-heavy-\(getuid())")
        self.configPath = configPath
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/heavy-queue.json")
        self.isAlive = isAlive
        self.commandForPid = commandForPid
    }

    var queueDir: URL { root.appendingPathComponent("queue") }

    // MARK: - Read

    /// The current queue: live entries only, split into running and waiting and each
    /// ordered the way the wrapper admits them.
    public func snapshot() -> HeavyQueueSnapshot {
        let (slots, cap) = capacity()
        var jobs = liveEntries()
        jobs.append(contentsOf: unregisteredSlotHolders(known: jobs))
        let (running, waiting) = Self.order(jobs)
        return HeavyQueueSnapshot(slots: slots, workerCap: cap, running: running, waiting: waiting)
    }

    /// `slots` and `workerCap` from the config, with the wrapper's own defaults.
    func capacity() -> (slots: Int, workerCap: Int) {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (1, 4) }
        let slots = (obj["slots"] as? Int).map { max(1, $0) } ?? 1
        let cap = (obj["workerCap"] as? Int).map { max(1, $0) } ?? 4
        return (slots, cap)
    }

    /// Registry entries whose wrapper process is still alive. Dead ones are left on
    /// disk for the wrapper to reap — the panel never deletes another job's files.
    func liveEntries() -> [HeavyJob] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: queueDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { Self.decode(try? Data(contentsOf: $0)) }
            .filter { isAlive($0.pid) }
    }

    /// Slots held by a wrapper that has no registry entry — an older wrapper, or one
    /// whose entry was lost. Surfaced so the panel never shows a busy queue as idle.
    func unregisteredSlotHolders(known: [HeavyJob]) -> [HeavyJob] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        let knownPids = Set(known.map(\.pid))
        var result: [HeavyJob] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix("slot-") {
            let slot = Int(dir.lastPathComponent.dropFirst("slot-".count)) ?? 0
            guard slot > 0,
                  let raw = try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8),
                  let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !knownPids.contains(pid), isAlive(pid)
            else { continue }
            result.append(HeavyJob(pid: pid, prio: 0, since: 0, slot: slot,
                                   cmd: commandForPid(pid) ?? "(unknown job)", cwd: ""))
        }
        return result
    }

    /// Split and order jobs the way the wrapper admits them: running by slot, waiting
    /// by priority (highest first), then by how long they've been queued. Pure.
    public static func order(_ jobs: [HeavyJob]) -> (running: [HeavyJob], waiting: [HeavyJob]) {
        let running = jobs.filter(\.running).sorted { ($0.slot, $0.pid) < ($1.slot, $1.pid) }
        let waiting = jobs.filter { !$0.running }.sorted {
            if $0.prio != $1.prio { return $0.prio > $1.prio }
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.pid < $1.pid
        }
        return (running, waiting)
    }

    /// Decode one registry entry. Hand-rolled over `JSONSerialization` because the
    /// wrapper writes `child: null` while waiting and the file may be mid-rewrite.
    static func decode(_ data: Data?) -> HeavyJob? {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int
        else { return nil }
        return HeavyJob(
            pid: pid,
            child: obj["child"] as? Int,
            prio: obj["prio"] as? Int ?? 0,
            since: obj["since"] as? Int ?? 0,
            started: obj["started"] as? Int,
            slot: obj["slot"] as? Int ?? 0,
            cmd: obj["cmd"] as? String ?? "",
            cwd: obj["cwd"] as? String ?? "")
    }

    // MARK: - Write

    /// Set a job's priority. The wrapper re-reads its own entry every poll, so this
    /// takes effect within one poll (~3s) — no signal needed.
    @discardableResult
    public func setPriority(pid: Int, to prio: Int) -> Bool {
        let file = queueDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        obj["prio"] = prio
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        // Same-directory temp + rename: a reader never sees a half-written entry.
        let tmp = queueDir.appendingPathComponent(".\(pid).panel.tmp")
        guard (try? out.write(to: tmp)) != nil else { return false }
        return (try? FileManager.default.replaceItemAt(file, withItemAt: tmp)) != nil
    }

    /// Move a waiting job to the head of the line: one better than the best priority
    /// currently queued. Returns the priority it was given.
    @discardableResult
    public func moveToFront(pid: Int, in snapshot: HeavyQueueSnapshot) -> Int {
        let best = snapshot.waiting.map(\.prio).max() ?? 0
        let prio = max(best + 1, 1)
        setPriority(pid: pid, to: prio)
        return prio
    }

    /// Nudge a job one step up or down the line by swapping priorities with its
    /// neighbour — the arrow buttons in the panel.
    public func nudge(pid: Int, up: Bool, in snapshot: HeavyQueueSnapshot) {
        let list = snapshot.waiting
        guard let i = list.firstIndex(where: { $0.pid == pid }) else { return }
        let j = up ? i - 1 : i + 1
        guard list.indices.contains(j) else { return }
        let mine = list[i], theirs = list[j]
        // Equal priorities are ordered by age, so a plain swap wouldn't move
        // anything — step past the neighbour instead.
        if mine.prio == theirs.prio {
            setPriority(pid: pid, to: mine.prio + (up ? 1 : -1))
        } else {
            setPriority(pid: pid, to: theirs.prio)
            setPriority(pid: theirs.pid, to: mine.prio)
        }
    }

    /// Change how many heavy jobs may run at once. The wrapper re-reads this every
    /// poll, so raising it lets jobs already in line through. Rules and every other
    /// key in the config are preserved.
    @discardableResult
    public func setSlots(_ slots: Int) -> Bool {
        guard slots >= 1 else { return false }
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["slots"] = slots
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: configPath, options: .atomic)) != nil
    }

    /// Cancel a job. SIGTERM to the wrapper, which forwards it to the running command
    /// and cleans up its slot and registry entry.
    @discardableResult
    public func cancel(pid: Int) -> Bool {
        kill(pid_t(pid), SIGTERM) == 0
    }

    // MARK: - Probes

    /// Signal 0 to test for a live process; EPERM means alive but not ours.
    public static let pidIsAlive: @Sendable (Int) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// The command line of a pid via `ps`, for slot holders with no registry entry.
    public static let psCommand: @Sendable (Int) -> String? = { pid in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }
}
