import Foundation

/// A listening Tilt server identifies its checkout even when launched outside juancode.
/// This is process ownership, not a claim that its services are healthy.
public struct TiltRuntime: Equatable, Sendable {
    public let pid: Int
    public let checkout: String
    public let project: String

    public var name: String { URL(fileURLWithPath: checkout).lastPathComponent }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// lsof's field format avoids whitespace splitting paths and process names.
    public static func tiltPids(_ output: String) -> [Int] {
        var pid: Int?
        var result = Set<Int>()
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()) }
            if line == "ctilt", let pid { result.insert(pid) }
        }
        return result.sorted()
    }

    public static func scan() async throws -> [TiltRuntime] {
        let listeners = try await ProcessRunner.capture("/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpc"], timeout: 5)
        guard listeners.ok || (listeners.exitCode == 1 && listeners.stdout.isEmpty && listeners.stderr.isEmpty) else {
            throw NSError(domain: "TiltRuntime", code: Int(listeners.exitCode))
        }
        var result: [TiltRuntime] = []
        for pid in tiltPids(listeners.stdout) {
            let cwd = try await ProcessRunner.capture("/usr/sbin/lsof",
                ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 5)
            guard let path = cwd.stdout.split(separator: "\n").first(where: { $0.first == "n" }) else { continue }
            let root = try await ProcessRunner.capture("/usr/bin/git",
                ["rev-parse", "--show-toplevel"], cwd: String(path.dropFirst()), timeout: 5)
            guard root.ok else { continue }
            let checkout = canonical(root.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let trees = try await ProcessRunner.capture("/usr/bin/git",
                ["worktree", "list", "--porcelain"], cwd: checkout, timeout: 5)
            guard trees.ok, let first = trees.stdout.split(separator: "\n").first,
                  first.hasPrefix("worktree ") else { continue }
            result.append(.init(pid: pid, checkout: checkout,
                                project: canonical(String(first.dropFirst(9)))))
        }
        return result
    }
}
