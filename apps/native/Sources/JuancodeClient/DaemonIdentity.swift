// Who the daemon on the other end of the socket is, and whether it is the one this
// launch meant to talk to.
//
// The Rust core is a separate process that deliberately outlives the app — a pty has
// to survive an app relaunch. The cost of that is the failure this file exists to
// make impossible: relaunch the app, reconnect to a daemon started hours ago under an
// older build and a different environment, and read a session list that is a mirror
// of what that daemon has been told. It looks authoritative and it is stale, and
// nothing on screen says so.
//
// Nothing here fails a boot. A stale daemon still owns live ptys, and refusing to
// connect would end them to fix a reporting problem. The whole answer is: say so,
// where the user is already looking.

import Foundation

/// The `daemon` object on `serverInfo`, as reported by `juancoded`. Absent for an
/// in-process core, which cannot be stale relative to its own app.
public struct DaemonIdentity: Sendable, Equatable {
    public let pid: Int
    /// When the daemon captured its identity at boot.
    public let startedAt: Date?
    /// The binary that is running. The app stats this same path to notice a rebuild.
    public let exePath: String?
    /// mtime of `exePath` **as the daemon saw it at boot**.
    public let buildStamp: Date?
    public let version: String?
    /// `JUANCODE_BUILD_ID` as the daemon saw it. `dev-app.sh` stamps one value into
    /// both processes, so in the sanctioned launch path this is an exact answer and
    /// the mtime comparison is only the fallback.
    public let buildId: String?
    public let dataDir: String?
    /// The per-project session cap the daemon actually enforces.
    public let sessionsPerProject: Int?

    public init(pid: Int, startedAt: Date?, exePath: String?, buildStamp: Date?,
                version: String?, buildId: String?, dataDir: String?,
                sessionsPerProject: Int?) {
        self.pid = pid
        self.startedAt = startedAt
        self.exePath = exePath
        self.buildStamp = buildStamp
        self.version = version
        self.buildId = buildId
        self.dataDir = dataDir
        self.sessionsPerProject = sessionsPerProject
    }

    /// Decode the handshake's `daemon` object. Every field except `pid` is optional
    /// on purpose: a daemon that could not read its own mtime should still identify
    /// itself, and a missing field means "unknown", never "matches".
    public init?(json: Any?) {
        guard let body = json as? [String: Any], let pid = body["pid"] as? Int else { return nil }
        self.pid = pid
        self.startedAt = Self.date(body["startedAt"])
        self.exePath = (body["exePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.buildStamp = Self.date(body["buildStamp"])
        self.version = body["version"] as? String
        self.buildId = (body["buildId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.dataDir = (body["dataDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.sessionsPerProject = body["sessionsPerProject"] as? Int
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let ms = raw as? Int else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// One line for a badge tooltip or a log, whether or not anything is wrong.
    public var summary: String {
        var parts = ["pid \(pid)"]
        if let version { parts.append("v\(version)") }
        if let startedAt { parts.append("up since \(Self.clock.string(from: startedAt))") }
        if let sessionsPerProject {
            parts.append("keeps \(sessionsPerProject == 0 ? "all" : "\(sessionsPerProject)") per project")
        }
        return parts.joined(separator: " · ")
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// What this app is, for the comparison. Deliberately tiny: a launch time and the
/// two environment values whose disagreement with the daemon's is what burns people.
public struct AppIdentity: Sendable, Equatable {
    /// When this app process started.
    public let launchedAt: Date
    /// `JUANCODE_BUILD_ID` in this process's environment, nil when nothing stamped it.
    public let buildId: String?
    /// `JUANCODE_SESSIONS_PER_PROJECT` in this process's environment, nil when unset.
    public let sessionsPerProject: Int?

    public init(launchedAt: Date, buildId: String?, sessionsPerProject: Int?) {
        self.launchedAt = launchedAt
        self.buildId = buildId
        self.sessionsPerProject = sessionsPerProject
    }

    public static var current: AppIdentity {
        let env = ProcessInfo.processInfo.environment
        return AppIdentity(
            launchedAt: processStartTime() ?? Date(),
            buildId: env["JUANCODE_BUILD_ID"].flatMap { $0.isEmpty ? nil : $0 },
            sessionsPerProject: env["JUANCODE_SESSIONS_PER_PROJECT"].flatMap(Int.init))
    }

    /// This process's real start time, from the kernel. `Date()` at boot would drift
    /// by however long the app spent launching, and the comparison this feeds — "did
    /// the daemon predate my launch" — is the one that has to be right.
    static func processStartTime(pid: pid_t = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)
            + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

/// One thing that is wrong with the daemon this app is connected to.
public struct DaemonWarning: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// The daemon is running a build the checkout has moved past.
        case staleBuild
        /// The daemon was already running before this app launched, so nothing set on
        /// this launch line reached it.
        case predatesLaunch
        /// The daemon's retention differs from what this app's environment asks for.
        case retentionMismatch
    }

    public let kind: Kind
    /// Short enough for a badge tooltip.
    public let headline: String
    /// The sentence that says what to do about it.
    public let detail: String

    public var id: String { kind.rawValue }

    public init(kind: Kind, headline: String, detail: String) {
        self.kind = kind
        self.headline = headline
        self.detail = detail
    }
}

public extension DaemonIdentity {
    /// Everything wrong with this daemon, worst first, or empty when it is the one
    /// this launch meant to reach.
    ///
    /// `binaryModifiedAt` is the mtime of `exePath` **now** — injected rather than
    /// stat'ed inside, so the comparison is testable without a filesystem. Call
    /// `warnings(against:)` for the live version.
    func warnings(against app: AppIdentity, binaryModifiedAt: Date?) -> [DaemonWarning] {
        var found: [DaemonWarning] = []

        // A build id mismatch is exact and needs no interpretation, so it wins over
        // the mtime heuristic that would otherwise say the same thing more vaguely.
        if let mine = app.buildId, let theirs = buildId, mine != theirs {
            found.append(DaemonWarning(
                kind: .staleBuild,
                headline: "daemon is build \(theirs), this app is \(mine)",
                detail: "The daemon (pid \(pid)) was started from build \(theirs) and this app "
                    + "is build \(mine). It is serving an older checkout. Restart it with "
                    + "`apps/native/scripts/dev-app.sh --restart-daemon`, which lists the live "
                    + "sessions it would end first."))
        } else if let built = buildStamp, let now = binaryModifiedAt, now > built.addingTimeInterval(1) {
            found.append(DaemonWarning(
                kind: .staleBuild,
                headline: "the core binary was rebuilt at \(Self.clock.string(from: now))",
                detail: "\(exePath ?? "The daemon binary") was rebuilt at "
                    + "\(Self.clock.string(from: now)), after the running daemon (pid \(pid)) "
                    + "started from the \(Self.clock.string(from: built)) build. Nothing you "
                    + "compiled since then is running. `apps/native/scripts/dev-app.sh "
                    + "--restart-daemon` restarts it and lists the live sessions that costs."))
        }

        // Only worth saying when it changes something, and only when nothing stronger
        // has already been said. A daemon older than this launch is normal and wanted
        // (that is how ptys survive); what makes it worth a line is that environment
        // set on the launch line stopped at the app. And a daemon already reported as
        // the wrong BUILD needs one restart, not two warnings describing it.
        if found.isEmpty, let started = startedAt, started < app.launchedAt,
           !environmentReached(app) {
            found.append(DaemonWarning(
                kind: .predatesLaunch,
                headline: "daemon predates this launch (up since "
                    + "\(Self.clock.string(from: started)))",
                detail: "The daemon has been running since "
                    + "\(Self.clock.string(from: started)), before this app launched at "
                    + "\(Self.clock.string(from: app.launchedAt)), so this launch did not start "
                    + "it. JUANCODE_* variables set on this launch line went to the app only — "
                    + "the daemon still has the environment it started with. "
                    + "`apps/native/scripts/dev-app.sh --daemon-status` says who owns it."))
        }

        if let mine = app.sessionsPerProject, let theirs = sessionsPerProject, mine != theirs {
            found.append(DaemonWarning(
                kind: .retentionMismatch,
                headline: "retention is \(describe(theirs)), not the \(describe(mine)) you asked for",
                detail: "This app was launched with JUANCODE_SESSIONS_PER_PROJECT=\(mine), but "
                    + "the daemon reads that once at ITS start and is enforcing "
                    + "\(describe(theirs)) per project. It prunes to that as sessions exit, so "
                    + "rows you expect to keep can disappear. Only restarting the daemon "
                    + "changes it."))
        }
        return found
    }

    /// The live comparison: stats `exePath` for its current mtime.
    func warnings(against app: AppIdentity = .current) -> [DaemonWarning] {
        let now = exePath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }
        return warnings(against: app, binaryModifiedAt: now)
    }

    /// Whether this app's environment demonstrably reached the daemon. Used to keep
    /// the "predates this launch" note quiet for the ordinary, healthy adoption where
    /// nothing actually differs.
    private func environmentReached(_ app: AppIdentity) -> Bool {
        if let mine = app.buildId, let theirs = buildId { return mine == theirs }
        return false
    }

    private func describe(_ cap: Int) -> String {
        cap == 0 ? "unlimited" : "\(cap) sessions"
    }
}
