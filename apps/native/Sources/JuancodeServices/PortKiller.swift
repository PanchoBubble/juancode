import Foundation
import Darwin

/// A process LISTENing on a TCP port, as reported by `lsof`.
public struct PortProcess: Sendable, Identifiable, Equatable {
    public let pid: Int32
    public let command: String
    public var id: Int32 { pid }
    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

/// Find and kill whatever is listening on a local TCP port — the "free up my stuck
/// dev-server port" utility. Discovery is `lsof`; termination is a POSIX signal
/// (`kill(2)`, same call the PTY teardown uses). Runs through `ProcessRunner`, which
/// inherits the user's environment untouched, so `lsof` resolves exactly as it would
/// in their terminal.
public enum PortKiller {
    /// Processes LISTENing on `port` (TCP), deduped by pid. Empty when the port is
    /// free — or when `lsof` can't be launched. Only listeners are reported, never
    /// clients holding an established connection to the port (e.g. a browser tab), so
    /// a Kill never targets the wrong side.
    public static func listeners(on port: Int) async -> [PortProcess] {
        // `lsof` exits non-zero when nothing matches, so `capture` (not `run`) and an
        // empty stdout is the "port is free" signal. `-Fpc` prints one `p<pid>` and
        // one `c<command>` record per process; nothing else.
        guard let out = try? await ProcessRunner.capture(
            "lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], timeout: 8
        ).stdout else { return [] }
        return parseListeners(lsofFieldOutput: out)
    }

    /// Parse `lsof -Fpc` field output into deduped processes. Each process is a
    /// `p<pid>` record optionally followed by a `c<command>` record; any other field
    /// lines are ignored. Split out from `listeners(on:)` so it's unit-testable
    /// without shelling out.
    static func parseListeners(lsofFieldOutput out: String) -> [PortProcess] {
        var result: [PortProcess] = []
        var seen = Set<Int32>()
        var pid: Int32?
        var command = ""
        func flush() {
            guard let pid, !seen.contains(pid) else { return }
            seen.insert(pid)
            result.append(PortProcess(pid: pid, command: command))
        }
        for line in out.split(whereSeparator: { $0.isNewline }) {
            let field = line.dropFirst()
            switch line.first {
            case "p": flush(); pid = Int32(field); command = ""
            case "c": command = String(field)
            default: break
            }
        }
        flush()
        return result
    }

    /// Kill everything LISTENing on `port`: `SIGTERM` first (lets a dev server release
    /// the port and reap children cleanly), then `SIGKILL` any survivor after a short
    /// grace period. Returns what was targeted plus whether the port is still in use
    /// afterwards (e.g. a process we lack permission to kill).
    @discardableResult
    public static func kill(port: Int) async -> (targeted: [PortProcess], stillInUse: Bool) {
        let targets = await listeners(on: port)
        guard !targets.isEmpty else { return ([], false) }

        for p in targets { _ = Darwin.kill(p.pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let survivors = await listeners(on: port)
        if !survivors.isEmpty {
            for p in survivors { _ = Darwin.kill(p.pid, SIGKILL) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let remaining = await listeners(on: port)
        return (targets, !remaining.isEmpty)
    }
}
