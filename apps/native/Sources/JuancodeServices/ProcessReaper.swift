import Foundation
import Darwin

/// A stuck `vitest` process tree: the launcher process plus every `vitest` worker
/// descended from it, as reported by `ps`.
public struct VitestTree: Sendable, Identifiable, Equatable {
    /// The topmost `vitest`-related process (the pnpm/vitest launcher).
    public let rootPid: Int32
    /// The launcher's full command line, for display.
    public let command: String
    /// Every pid in the tree (root + workers), sorted.
    public let pids: [Int32]
    /// Summed RSS of the whole tree in bytes. Approximate — forks share pages, so
    /// this over-counts; it's an at-a-glance "how much is this holding" number.
    public let totalRSSBytes: Int64
    public var id: Int32 { rootPid }
    public var processCount: Int { pids.count }

    public init(rootPid: Int32, command: String, pids: [Int32], totalRSSBytes: Int64) {
        self.rootPid = rootPid
        self.command = command
        self.pids = pids
        self.totalRSSBytes = totalRSSBytes
    }
}

/// Find and kill stuck `vitest` worker trees — the ones a port scan can't see because
/// vitest workers hold no listening port. A `vitest related` run left in watch mode
/// keeps a full fork pool alive; this finds those trees and reaps them.
///
/// Discovery is `ps`; termination is a POSIX signal (`kill(2)`, the same call the PTY
/// teardown and `PortKiller` use). Runs through `ProcessRunner`, which inherits the
/// user's environment untouched, so `ps` resolves exactly as it would in their terminal.
public enum ProcessReaper {
    /// Stuck `vitest` process trees, largest (by RSS) first. Empty when none are
    /// running — or when `ps` can't be launched.
    public static func stuckVitestTrees() async -> [VitestTree] {
        // `pid=,ppid=,rss=,command=` with empty headers prints one bare record per
        // process: pid, ppid, RSS in KB, then the full command line.
        guard let out = try? await ProcessRunner.capture(
            "ps", ["-axo", "pid=,ppid=,rss=,command="], timeout: 8
        ).stdout else { return [] }
        return parseVitestTrees(psOutput: out)
    }

    /// Parse `ps -axo pid=,ppid=,rss=,command=` output into grouped `vitest` trees.
    /// A process belongs to a tree if its command mentions `vitest`; the tree root is
    /// the highest such ancestor (its parent is not a `vitest` process). Split out
    /// from `stuckVitestTrees()` so it's unit-testable without shelling out.
    static func parseVitestTrees(psOutput out: String) -> [VitestTree] {
        struct Proc { let ppid: Int32; let rssKB: Int64; let command: String }
        var procs: [Int32: Proc] = [:]

        for raw in out.split(whereSeparator: { $0.isNewline }) {
            var rest = raw.drop(while: { $0 == " " || $0 == "\t" })
            func nextInt() -> Int32? {
                let tok = rest.prefix(while: { $0 != " " && $0 != "\t" })
                rest = rest.dropFirst(tok.count).drop(while: { $0 == " " || $0 == "\t" })
                return Int32(tok)
            }
            guard let pid = nextInt(), let ppid = nextInt(),
                  let rssTok = Int64(rest.prefix(while: { $0 != " " && $0 != "\t" }))
            else { continue }
            rest = rest.drop(while: { $0 != " " && $0 != "\t" }).drop(while: { $0 == " " || $0 == "\t" })
            procs[pid] = Proc(ppid: ppid, rssKB: rssTok, command: String(rest))
        }

        let vitestPids = Set(procs.filter { isVitestProcess($0.value.command) }.map(\.key))
        guard !vitestPids.isEmpty else { return [] }

        // Highest vitest ancestor: climb while the parent is also a vitest process.
        func root(of pid: Int32) -> Int32 {
            var cur = pid
            var hops = 0
            while let p = procs[cur], vitestPids.contains(p.ppid), hops < 4096 {
                cur = p.ppid
                hops += 1
            }
            return cur
        }

        var groups: [Int32: [Int32]] = [:]
        for pid in vitestPids { groups[root(of: pid), default: []].append(pid) }

        return groups.map { rootPid, pids in
            let total = pids.reduce(Int64(0)) { $0 + (procs[$1]?.rssKB ?? 0) * 1024 }
            return VitestTree(rootPid: rootPid,
                              command: procs[rootPid]?.command ?? "",
                              pids: pids.sorted(),
                              totalRSSBytes: total)
        }
        .sorted { $0.totalRSSBytes > $1.totalRSSBytes }
    }

    /// Whether a command line is an actual `vitest` process (the launcher or a worker),
    /// not merely a shell or editor whose arguments happen to mention "vitest". Both the
    /// launcher (`node …/pnpm vitest related`) and workers (`node (vitest 2)`) run under
    /// node, so require the executable to be node.
    static func isVitestProcess(_ command: String) -> Bool {
        guard command.contains("vitest") else { return false }
        let exe = command.prefix(while: { $0 != " " && $0 != "\t" })
        let base = exe.split(separator: "/").last.map(String.init) ?? String(exe)
        return base == "node" || base.hasPrefix("node ")
    }

    /// Kill a whole tree: `SIGTERM` every pid first (lets vitest tear its pool down
    /// cleanly), then `SIGKILL` any survivor after a short grace period. Returns what
    /// was targeted plus whether anything is still alive (e.g. a pid we can't signal).
    @discardableResult
    public static func kill(tree: VitestTree) async -> (targeted: [Int32], stillAlive: Bool) {
        let pids = tree.pids
        guard !pids.isEmpty else { return ([], false) }

        for p in pids { _ = Darwin.kill(p, SIGTERM) }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let survivors = pids.filter { Darwin.kill($0, 0) == 0 }
        if !survivors.isEmpty {
            for p in survivors { _ = Darwin.kill(p, SIGKILL) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return (pids, pids.contains { Darwin.kill($0, 0) == 0 })
    }
}
