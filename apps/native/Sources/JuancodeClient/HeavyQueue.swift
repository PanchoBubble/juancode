import Foundation

/// One memory-heavy command going through the global `heavy` slot queue — either
/// holding a slot (`slot > 0`) or waiting in line.
///
/// The queue itself lives in the core (`juancoded-core/src/heavy.rs`), which reads
/// the shared filesystem registry `~/.claude/bin/heavy` writes and pushes a fresh
/// snapshot on every change. Nothing here touches that registry: this is the value
/// the `heavyQueue` frame carries, and the two helpers that turn "run this next"
/// into the priority number the core is asked to write.
public struct HeavyJob: Sendable, Identifiable, Equatable {
    /// The wrapper's pid — also the registry filename and the id a cancel names.
    public let pid: Int
    /// The actual command's pid, once it is running.
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

    /// One job off the wire. Lenient in the same places the core's own decoder is:
    /// `child` and `started` are null while a job waits.
    public init?(wire: Any?) {
        guard let obj = wire as? [String: Any], let pid = obj["pid"] as? Int else { return nil }
        self.init(pid: pid,
                  child: obj["child"] as? Int,
                  prio: obj["prio"] as? Int ?? 0,
                  since: obj["since"] as? Int ?? 0,
                  started: obj["started"] as? Int,
                  slot: obj["slot"] as? Int ?? 0,
                  cmd: obj["cmd"] as? String ?? "",
                  cwd: obj["cwd"] as? String ?? "")
    }
}

/// The whole queue at a moment: its capacity and the two ordered lists the panel
/// draws. Always complete — the frame is never a delta, so replace wholesale.
public struct HeavyQueueSnapshot: Sendable, Equatable {
    public var slots: Int
    public var workerCap: Int
    /// Already ordered by the core, by slot.
    public var running: [HeavyJob]
    /// Already ordered by the core, the way the wrappers will admit themselves:
    /// priority first, then how long each has been queued.
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

    /// A `heavyQueue` frame's body. Nil when it is not one.
    public init?(wire body: [String: Any]) {
        guard let slots = body["slots"] as? Int else { return nil }
        let jobs = { (key: String) in
            (body[key] as? [Any] ?? []).compactMap(HeavyJob.init(wire:))
        }
        self.init(slots: slots,
                  workerCap: body["workerCap"] as? Int ?? 4,
                  running: jobs("running"),
                  waiting: jobs("waiting"))
    }

    /// The priority that puts a job at the head of the line: one better than the best
    /// priority currently queued.
    ///
    /// The arithmetic is here rather than in the core's frame set because the core's
    /// mutation is deliberately `heavySetPriority` alone — the waiting wrapper admits
    /// itself off a number in its own entry, so a number is the only thing anybody can
    /// change. This turns a click into that number.
    public var moveToFrontPriority: Int { max((waiting.map(\.prio).max() ?? 0) + 1, 1) }

    /// The priority rewrites that move `pid` one place up or down the waiting line,
    /// as `(pid, prio)` pairs to send in order. Empty when it cannot move.
    ///
    /// Equal priorities are ordered by age, so a plain swap would move nothing — step
    /// past the neighbour instead.
    public func nudgePriorities(pid: Int, up: Bool) -> [(pid: Int, prio: Int)] {
        guard let i = waiting.firstIndex(where: { $0.pid == pid }) else { return [] }
        let j = up ? i - 1 : i + 1
        guard waiting.indices.contains(j) else { return [] }
        let mine = waiting[i], theirs = waiting[j]
        if mine.prio == theirs.prio {
            return [(pid, mine.prio + (up ? 1 : -1))]
        }
        return [(pid, theirs.prio), (theirs.pid, mine.prio)]
    }
}
