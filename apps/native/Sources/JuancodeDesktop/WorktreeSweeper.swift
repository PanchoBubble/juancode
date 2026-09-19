import Foundation
import JuancodeServices

/// Settings → Worktrees: the app's front end for the worktree sweeper that
/// `scripts/worktree-sweep.mjs` implements and
/// `apps/native/scripts/worktree-sweeper-agent.sh` schedules.
///
/// Nothing here decides what is safe to remove. The verdicts, the three refusals
/// the sweep script adds on top of them (dry run by default, no daemon no sweep,
/// liveness re-checked immediately before each removal) and the plist all stay
/// where they are — this file shells out to them and parses what they print. The
/// reason is that the sweep runs from launchd at 04:30 with no app in the picture,
/// so a second implementation in Swift would be a second answer to "is this tree
/// safe to delete" that nobody would ever see disagree.
///
/// What the app adds is the part a shell script cannot: a dry run you can read,
/// with sizes, before anything is armed.

// MARK: - the sweep's `--json` output

/// One worktree's verdict, decoded from `worktree-sweep.mjs --json`.
public struct WorktreeSweepRow: Decodable, Sendable, Identifiable, Equatable {
    public var path: String
    public var branch: String
    public var head: String?
    /// `"remove"` or `"keep"`. Anything that is not `remove` is kept.
    public var verdict: String
    /// The verdict's machine code: `FRESH`, `LIVE`, `DIRTY`, `MAIN_CHECKOUT`, …
    public var code: String
    public var reason: String
    public var ageHours: Double?
    /// Count of `git status --porcelain` lines, not a flag.
    public var dirty: Int
    public var aheadMain: Int
    /// `nil` when the branch has no counterpart on origin.
    public var pushed: Bool?
    public var removed: Bool

    public var id: String { path }
    public var willRemove: Bool { verdict == "remove" }

    /// `wt:<name>` for an agent worktree, otherwise the last path component —
    /// the same shortening the CLI report uses, recomputed here so the JSON
    /// stays the narrow contract it is.
    public var short: String {
        if let tail = path.components(separatedBy: "-worktrees/").last, path.contains("-worktrees/") {
            return "wt:" + tail
        }
        return (path as NSString).lastPathComponent
    }

    public var ageLabel: String {
        guard let ageHours else { return "age unknown" }
        if ageHours < 1 { return String(format: "%.0fm", ageHours * 60) }
        if ageHours < 48 { return String(format: "%.1fh", ageHours) }
        return String(format: "%.1fd", ageHours / 24)
    }
}

/// A whole dry run: the header the script reports plus every verdict.
public struct WorktreeSweepPreview: Decodable, Sendable, Equatable {
    public var startedAt: String
    /// `DRY-RUN`, `APPLY`, or one of the script's `REFUSED (…)` strings.
    public var mode: String
    public var repoRoot: String
    public var maxAgeDays: Double
    /// `nil` when the daemon was not checked at all.
    public var daemonReachable: Bool?
    public var daemonChecked: Bool
    public var processesSampled: Bool
    public var ghAvailable: Bool
    public var logFile: String
    public var removed: [String]
    public var rows: [WorktreeSweepRow]

    public var wouldRemove: [WorktreeSweepRow] { rows.filter(\.willRemove) }
    public var kept: [WorktreeSweepRow] { rows.filter { !$0.willRemove } }

    /// Whether a real (`--apply`) sweep could remove anything right now. Both
    /// liveness sources have to be answering: a daemon that is down is not "no
    /// sessions are running", it is "we cannot see what is running".
    public var couldRemove: Bool { daemonReachable == true && processesSampled }

    /// Why it could not, in the pane's words. `nil` when it could.
    public var blockedReason: String? {
        if daemonReachable == false {
            return "The daemon is not answering, so the sweep cannot tell which worktrees have "
                + "sessions running in them. Nothing would be removed — no daemon, no sweep."
        }
        if !processesSampled {
            return "lsof/ps reported no processes, so the second liveness check is blind. "
                + "Nothing would be removed."
        }
        return nil
    }

    /// PR state is a keep signal, so losing `gh` makes the preview more
    /// conservative than a real sweep with `gh` working, not less.
    public var ghWarning: String? {
        ghAvailable ? nil
            : "gh is unavailable, so PR state is unknown and every tree with commits is being kept."
    }
}

// MARK: - `worktree-sweeper-agent.sh status`

/// What the installer says about the LaunchAgent right now.
public struct WorktreeSweeperStatus: Sendable, Equatable {
    public var installed = false
    /// The plist's command line carries `--apply`.
    public var armed = false
    public var loaded = false
    public var plist = ""
    public var checkout = ""
    /// Set when the installed job sweeps a checkout other than the one we found.
    public var otherCheckout: String?
    public var days: String = ""
    public var schedule = ""
    public var runLog = ""
    public var raw = ""

    public static let notInstalled = WorktreeSweeperStatus()
}

// MARK: - the run log

/// The last `=== …` block in `~/.juancode/logs/worktree-sweep.log`.
public struct WorktreeSweepLastRun: Sendable, Equatable {
    public var startedAt: Date?
    public var startedAtRaw = ""
    public var mode = ""
    public var root = ""
    public var days = ""
    public var trees = 0
    public var removed = 0
    public var wouldRemove = 0
    public var kept = 0
    public var daemonUnreachable = false
    /// The paths the run actually removed, from its `REMOVED ` lines.
    public var removedPaths: [String] = []
}

// MARK: - locating the scripts

/// Absolute paths to the one checkout the sweeper may be pointed at.
public struct WorktreeSweeperPaths: Sendable, Equatable {
    /// The MAIN checkout, never a worktree: the plist must not be pinned to a
    /// directory the sweep is itself allowed to delete, and the installer refuses
    /// to be run from one.
    public var mainCheckout: String
    public var agentScript: String
    public var sweepScript: String

    public init(mainCheckout: String) {
        self.mainCheckout = mainCheckout
        agentScript = mainCheckout + "/apps/native/scripts/worktree-sweeper-agent.sh"
        sweepScript = mainCheckout + "/scripts/worktree-sweep.mjs"
    }
}

public enum WorktreeSweeper {
    /// Where the run log lives, matching the script's own default.
    public static var logFile: String {
        let dir = ProcessInfo.processInfo.environment["JUANCODE_LOG_DIR"]
            ?? NSHomeDirectory() + "/.juancode/logs"
        return dir + "/worktree-sweep.log"
    }

    // MARK: locating

    /// True when `dir` is a juancode checkout holding both halves of the sweeper.
    public static func isSweeperCheckout(_ dir: String, exists: (String) -> Bool) -> Bool {
        exists(dir + "/scripts/worktree-sweep.mjs")
            && exists(dir + "/apps/native/scripts/worktree-sweeper-agent.sh")
    }

    /// Walk up from `path` looking for a checkout that holds the sweeper.
    public static func checkoutAbove(_ path: String, exists: (String) -> Bool) -> String? {
        var dir = (path as NSString).standardizingPath
        while dir.count > 1 {
            if isSweeperCheckout(dir, exists: exists) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// A linked worktree's `.git` is a FILE reading `gitdir: <main>/.git/worktrees/<name>`.
    /// Recover the main checkout from it; `nil` when the text is not that.
    public static func mainCheckout(fromGitFile text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitDir[gitDir.startIndex..<range.lowerBound])
    }

    /// Resolve the main checkout for a directory that may itself be a worktree.
    public static func resolveMainCheckout(
        _ dir: String,
        exists: (String) -> Bool,
        read: (String) -> String?
    ) -> String {
        let dotGit = dir + "/.git"
        guard exists(dotGit), let text = read(dotGit),
              let main = mainCheckout(fromGitFile: text),
              isSweeperCheckout(main, exists: exists)
        else { return dir }
        return main
    }

    /// Find the checkout whose sweeper this pane drives.
    ///
    /// `JUANCODE_REPO_ROOT` wins, then any hint the app already holds (a session's
    /// repo root), then the running binary, the working directory, and finally this
    /// source file's own path — which is the right answer for a `swift run` build and
    /// harmless when it no longer exists. Whatever is found is normalised to the MAIN
    /// checkout, because the app itself usually runs from a worktree.
    public static func locate(hints: [String] = [], file: String = #filePath) -> WorktreeSweeperPaths? {
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.fileExists(atPath: $0) }
        let read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["JUANCODE_REPO_ROOT"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append(contentsOf: hints.filter { !$0.isEmpty })
        candidates.append(Bundle.main.bundleURL.path)
        candidates.append(fm.currentDirectoryPath)
        candidates.append(file)
        for candidate in candidates {
            guard let root = checkoutAbove(candidate, exists: exists) else { continue }
            return WorktreeSweeperPaths(
                mainCheckout: resolveMainCheckout(root, exists: exists, read: read))
        }
        return nil
    }

    // MARK: parsing

    public static func decodePreview(_ stdout: String) throws -> WorktreeSweepPreview {
        // The script says "running the sweep now" on stderr, but a stray line on
        // stdout would still break a strict decode, so start at the first brace.
        guard let start = stdout.firstIndex(of: "{"),
              let data = String(stdout[start...]).data(using: .utf8)
        else { throw WorktreeSweeperError.noJSON(stdout) }
        return try JSONDecoder().decode(WorktreeSweepPreview.self, from: data)
    }

    /// Parse `worktree-sweeper-agent.sh status`, which prints to stderr.
    public static func parseStatus(_ text: String) -> WorktreeSweeperStatus {
        var s = WorktreeSweeperStatus.notInstalled
        s.raw = text
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "worktree-sweeper: ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NOT installed") { s.installed = false }
            else if line.hasPrefix("installed: ") {
                s.installed = true
                s.plist = String(line.dropFirst("installed: ".count))
            } else if line.hasPrefix("mode:") {
                s.armed = value(after: "mode:", in: line) == "ARMED"
            } else if line.hasPrefix("checkout:") {
                // "…/juancode (this one)"
                s.checkout = value(after: "checkout:", in: line)
                    .replacingOccurrences(of: " (this one)", with: "")
            } else if line.hasPrefix("it sweeps ANOTHER CHECKOUT:") {
                let rest = value(after: "it sweeps ANOTHER CHECKOUT:", in: line)
                s.otherCheckout = rest.components(separatedBy: " (you are in ").first ?? rest
            } else if line.hasPrefix("days:") {
                s.days = value(after: "days:", in: line)
            } else if line.hasPrefix("schedule:") {
                s.schedule = value(after: "schedule:", in: line)
            } else if line.hasPrefix("run log:") {
                s.runLog = value(after: "run log:", in: line)
            } else if line.hasPrefix("not loaded in ") {
                s.loaded = false
            } else if line.hasPrefix("loaded in ") {
                s.loaded = true
            }
        }
        return s
    }

    private static func value(after key: String, in line: String) -> String {
        String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The most recent run in the log, or `nil` when there is no run in it.
    ///
    /// Header shape (the mode may contain spaces, hence the split on ` root=`):
    /// `=== <iso> <MODE> root=<path> days=N trees=N removed=N would-remove=N kept=N [flags]`
    public static func parseLastRun(log: String) -> WorktreeSweepLastRun? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.lastIndex(where: { $0.hasPrefix("=== ") }) else { return nil }
        let header = lines[headerIndex]
        guard let rootRange = header.range(of: " root=") else { return nil }

        var run = WorktreeSweepLastRun()
        let prefix = String(header[header.index(header.startIndex, offsetBy: 4)..<rootRange.lowerBound])
        let stamp = prefix.split(separator: " ", maxSplits: 1).map(String.init)
        run.startedAtRaw = stamp.first ?? ""
        run.startedAt = sweepLogDate(run.startedAtRaw)
        run.mode = stamp.count > 1 ? stamp[1] : ""

        let tail = String(header[rootRange.upperBound...])
        // The root may contain no spaces in practice; everything after it is `k=v`.
        let fields = tail.split(separator: " ").map(String.init)
        run.root = fields.first ?? ""
        for field in fields.dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "days": run.days = parts[1]
            case "trees": run.trees = Int(parts[1]) ?? 0
            case "removed": run.removed = Int(parts[1]) ?? 0
            case "would-remove": run.wouldRemove = Int(parts[1]) ?? 0
            case "kept": run.kept = Int(parts[1]) ?? 0
            case "daemon": run.daemonUnreachable = parts[1] == "UNREACHABLE"
            default: break
            }
        }
        for line in lines[(headerIndex + 1)...] {
            if line.hasPrefix("=== ") { break }
            guard line.hasPrefix("REMOVED ") else { continue }
            let rest = String(line.dropFirst("REMOVED ".count)).trimmingCharacters(in: .whitespaces)
            if let path = rest.split(separator: " ").first { run.removedPaths.append(String(path)) }
        }
        return run
    }

    /// The log's stamps carry milliseconds. Built per call: `ISO8601DateFormatter`
    /// is not `Sendable`, so it cannot be a shared `static let` here.
    static func sweepLogDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// `du -sk` output → bytes per path.
    public static func parseDiskUsage(_ out: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            sizes[parts[1].trimmingCharacters(in: .whitespaces)] = kb * 1024
        }
        return sizes
    }

    /// `du -h`-style, locale-free so it reads the same as the reclaim log.
    public static func formatSize(_ bytes: Int64) -> String {
        let g = 1024.0 * 1024 * 1024
        let d = Double(bytes)
        if d >= g { return String(format: "%.1fG", d / g) }
        if d >= 1024 * 1024 { return String(format: "%.0fM", d / (1024 * 1024)) }
        if d >= 1024 { return String(format: "%.0fK", d / 1024) }
        return "\(bytes)B"
    }

    // MARK: running

    /// Run something with extra environment entries and the parent environment
    /// otherwise untouched — `/usr/bin/env K=V cmd …`, because `ProcessRunner`
    /// deliberately inherits the environment verbatim.
    public static func envInvocation(
        _ env: [String: String], _ command: String, _ args: [String]
    ) -> (executable: String, args: [String]) {
        guard !env.isEmpty else { return (command, args) }
        let assignments = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
        return ("/usr/bin/env", assignments + [command] + args)
    }

    public static func run(
        _ paths: WorktreeSweeperPaths,
        _ args: [String],
        days: Int?,
        confirmArming: Bool = false,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        var env: [String: String] = [:]
        if let days { env["JUANCODE_SWEEP_DAYS"] = String(days) }
        // The installer asks on a terminal before arming; there is no terminal here,
        // so the pane's own confirmation is what this stands for. Set on nothing else.
        if confirmArming { env["JUANCODE_SWEEPER_ARM_CONFIRMED"] = "1" }
        let call = envInvocation(env, "/bin/bash", [paths.agentScript] + args)
        return try await ProcessRunner.capture(
            call.executable, call.args, cwd: paths.mainCheckout, timeout: timeout)
    }
}

public enum WorktreeSweeperError: Error, LocalizedError {
    case noCheckout
    case noJSON(String)
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .noCheckout:
            return "Could not find the juancode checkout that holds scripts/worktree-sweep.mjs. "
                + "Set JUANCODE_REPO_ROOT to it."
        case .noJSON(let out):
            let tail = out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            return "The sweep printed no JSON.\n\(tail)"
        case .script(let message):
            return message
        }
    }
}

