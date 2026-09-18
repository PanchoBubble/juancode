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
    /// Who will end this daemon, as the daemon itself sees it right now.
    public let owner: DaemonOwner

    public init(pid: Int, startedAt: Date?, exePath: String?, buildStamp: Date?,
                version: String?, buildId: String?, dataDir: String?,
                sessionsPerProject: Int?, owner: DaemonOwner = DaemonOwner(state: nil, pid: nil, grace: nil)) {
        self.pid = pid
        self.startedAt = startedAt
        self.exePath = exePath
        self.buildStamp = buildStamp
        self.version = version
        self.buildId = buildId
        self.dataDir = dataDir
        self.sessionsPerProject = sessionsPerProject
        self.owner = owner
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
        self.owner = DaemonOwner(json: body)
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
        parts.append(owner.summary)
        return parts.joined(separator: " · ")
    }

    /// For a daemon that outlives the app: what keeps it alive, and which build the
    /// sessions it is holding are running on. Nil when quitting the app ends it.
    ///
    /// The build belongs in this line and not only in the staleness warning. Choosing
    /// to keep sessions across app restarts is choosing to keep the PROCESS that holds
    /// them, and that process is the one thing a rebuild does not touch — so the moment
    /// the UI says "these survive a quit" is the moment it has to say what they are
    /// surviving on.
    var persistence: String? {
        guard owner.outlivesTheApp else { return nil }
        let keeper = owner.managed == .launchd
            ? "launchd keeps it running across quits, logout and reboot"
            : "it was started with JUANCODE_DAEMON_PERSIST=1, so quitting leaves it running"
        var line = "Sessions survive quitting the app: \(keeper) (daemon pid \(pid))."
        if let buildId {
            line += " Build \(buildId)."
        } else if let buildStamp {
            line += " Built at \(Self.clock.string(from: buildStamp)), unstamped."
        } else {
            line += " Build UNSTAMPED — it cannot be matched against this checkout."
        }
        return line
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Who will end the daemon, and after how long.
///
/// A daemon nobody claimed is not broken — that is `cargo run -p juancoded`, and the
/// deliberate answer there is "outlive everything". It is worth SAYING, though, because
/// an unowned daemon is the one that becomes the stale 09:39 process at PPID 1 that
/// this whole area of the code exists for.
public struct DaemonOwner: Sendable, Equatable {
    public enum State: String, Sendable {
        /// A live launch owns it and will reap it when it exits.
        case owned
        /// Its launch is gone and the daemon's own countdown to self-exit is running.
        case orphaned
        /// Nobody claimed it. Nothing will end it.
        case unowned
    }

    /// What was DECLARED about a daemon no launch owns.
    ///
    /// This is the difference between an accident and a decision, and `state` alone
    /// cannot carry it: a daemon started to outlive the app and a daemon nobody got
    /// round to claiming are both `unowned`, and both keep their ptys across a quit.
    /// Only one of them was meant.
    public enum Managed: String, Sendable {
        /// The LaunchAgent's (`com.juanone.juancoded`). Survives logout and reboot.
        case launchd
        /// Started with `JUANCODE_DAEMON_PERSIST=1`, which writes the intent into the
        /// ownership record so it can be said here.
        case persistent
    }

    /// Nil for a daemon too old to report ownership at all, which is a different
    /// answer from `unowned` and must not be flattened into it.
    public let state: State?
    /// The process that owns it, when there is one.
    public let pid: Int?
    /// How long the daemon waits after its owner is gone before ending itself. Zero
    /// means the watchdog is switched off.
    public let grace: TimeInterval?
    /// Who keeps it alive when no launch does. Nil for an owned daemon, and for an
    /// unowned one nobody declared.
    public let managed: Managed?

    public init(state: State?, pid: Int?, grace: TimeInterval?, managed: Managed? = nil) {
        self.state = state
        self.pid = pid
        self.grace = grace
        self.managed = managed
    }

    /// Decode the ownership keys off the `daemon` object.
    public init(json body: [String: Any]) {
        self.state = (body["ownerState"] as? String).flatMap(State.init(rawValue:))
        self.pid = body["ownerPid"] as? Int
        self.grace = (body["ownerGraceMs"] as? Int).map { TimeInterval($0) / 1000 }
        self.managed = (body["ownerManaged"] as? String).flatMap(Managed.init(rawValue:))
    }

    /// Whether anything at all will end this daemon.
    public var willBeReaped: Bool {
        guard let state else { return false }
        return state != .unowned && (grace ?? 0) > 0
    }

    /// Whether the sessions in this daemon are still there after the app quits — the
    /// one question the mode exists to answer.
    ///
    /// Deliberately keyed on the DECLARATION and not on `state == .unowned`. An
    /// undeclared unowned daemon does outlive the app, and saying "your sessions are
    /// safe" about a process nobody meant to keep is the promise this whole area of
    /// the code exists to stop making.
    public var outlivesTheApp: Bool { managed != nil }

    /// One clause for the identity line.
    public var summary: String {
        if let managed {
            switch managed {
            case .launchd: return "managed by launchd — outlives app quits, logout and reboot"
            case .persistent: return "PERSISTENT — started to outlive the app; its sessions survive a quit"
            }
        }
        switch state {
        case .owned:
            let seconds = Int(grace ?? 0)
            return pid.map { "owned by pid \($0)\(seconds > 0 ? ", self-exits \(seconds)s after it goes" : "")" }
                ?? "owned"
        case .orphaned:
            return "ORPHANED — its launch is gone and it is shutting down"
        case .unowned:
            return "unowned — nothing will end it, and nothing said that was meant"
        case nil:
            return "ownership unreported"
        }
    }
}

/// What this app is, for the comparison. Deliberately tiny: the two environment
/// values whose disagreement with the daemon's is what burns people.
public struct AppIdentity: Sendable, Equatable {
    /// `JUANCODE_BUILD_ID` in this process's environment, nil when nothing stamped it.
    public let buildId: String?
    /// `JUANCODE_SESSIONS_PER_PROJECT` in this process's environment, nil when unset.
    public let sessionsPerProject: Int?

    /// The cap this launch would enforce: the environment when it says something,
    /// and otherwise the default both cores share — 0, keep everything. Spelled here
    /// rather than read from `Config` so the comparison stays a pure value type, and
    /// kept as a named constant so the day the default moves, it moves in one place.
    public static let defaultSessionsPerProject = 0

    public var effectiveSessionsPerProject: Int {
        sessionsPerProject ?? Self.defaultSessionsPerProject
    }

    public init(buildId: String?, sessionsPerProject: Int?) {
        self.buildId = buildId
        self.sessionsPerProject = sessionsPerProject
    }

    public static var current: AppIdentity {
        let env = ProcessInfo.processInfo.environment
        return AppIdentity(
            buildId: env["JUANCODE_BUILD_ID"].flatMap { $0.isEmpty ? nil : $0 },
            sessionsPerProject: env["JUANCODE_SESSIONS_PER_PROJECT"].flatMap(Int.init))
    }
}

/// One thing that is wrong with the daemon this app is connected to.
public struct DaemonWarning: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// The daemon is running a build the checkout has moved past.
        case staleBuild
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
                    + "`scripts/dev-daemon.sh restart`, which lists the live sessions it would "
                    + "end first — and, when launchd is the one keeping it alive, sends you to "
                    + "`scripts/dev-daemon.sh agent restart` instead of quietly fighting it."))
        } else if let built = buildStamp, let now = binaryModifiedAt, now > built.addingTimeInterval(1) {
            found.append(DaemonWarning(
                kind: .staleBuild,
                headline: "the core binary was rebuilt at \(Self.clock.string(from: now))",
                detail: "\(exePath ?? "The daemon binary") was rebuilt at "
                    + "\(Self.clock.string(from: now)), after the running daemon (pid \(pid)) "
                    + "started from the \(Self.clock.string(from: built)) build. Nothing you "
                    + "compiled since then is running. `scripts/dev-daemon.sh restart` "
                    + "restarts it and lists the live sessions that costs."))
        }

        // An unset variable is not "no opinion": it is the default, and the default
        // keeps everything. So the comparison is against the cap this launch would
        // enforce, not only against one somebody typed — a daemon started before the
        // default changed is still pruning, and saying nothing lets the app present
        // its own (unlimited) default as if it applied to the rows on screen.
        if let theirs = sessionsPerProject, theirs != app.effectiveSessionsPerProject {
            let mine = app.effectiveSessionsPerProject
            let source = app.sessionsPerProject == nil
                ? "This app was launched with no JUANCODE_SESSIONS_PER_PROJECT, which means "
                    + "\(describe(mine)), but "
                : "This app was launched with JUANCODE_SESSIONS_PER_PROJECT=\(mine), but "
            found.append(DaemonWarning(
                kind: .retentionMismatch,
                headline: "retention is \(describe(theirs)), not the \(describe(mine)) this app expects",
                detail: source
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

    private func describe(_ cap: Int) -> String {
        cap == 0 ? "unlimited" : "\(cap) sessions"
    }
}
