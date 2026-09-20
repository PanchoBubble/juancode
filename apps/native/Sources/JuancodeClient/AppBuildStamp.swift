// Whether the app on screen is the app this checkout would build.
//
// `DaemonIdentity` next door answers the same question about the core: the daemon
// outlives the app, so it can be serving an older build than the one you compiled,
// and it says so. Nothing said it about the app itself — and on 2026-09-20 that cost
// a round trip. A toolbar fix landed on main at 12:00 on the 19th; the running bundle
// had been built at 10:30 from a checkout that never had the commit, so the fix was
// invisible and got reported as a bug against code that already worked.
//
// The trap that makes this easy to hit: `swift build` does NOT refresh the .app
// bundle. `dev-app.sh` assembles it, and the bundle is what the Dock launches — so
// "I rebuilt" and "I am running the new code" are separate claims and nothing on
// screen distinguished them.
//
// The answer here is deliberately small. The bundle is stamped at assembly time with
// the commit it was built from (`scripts/source-stamp.sh`), and at runtime the app
// asks git how far that checkout has moved since — against its own HEAD, and against
// its upstream ref, because the drift that burned us was in the SECOND one. Measured
// on that checkout: 2 commits between the build and its own HEAD, 19 between the build
// and origin/main. HEAD alone would have said "two commits, nothing to see".
//
// Nothing here blocks or rebuilds anything. It is an indicator, and it stays quiet
// for the one-commit drift you have the moment you commit.

import Foundation
import JuancodeCore

/// What the running bundle says about the source it was built from. Nil for a bare
/// SPM binary (`swift run juancode`), which has no Info.plist to stamp — an honest
/// "cannot tell", never a silent "matches".
public struct AppBuildStamp: Sendable, Equatable {
    /// The checkout the bundle was assembled from. The comparison runs against this
    /// path, not against wherever the app happens to be launched from.
    public let sourceRoot: String
    /// Full sha of that checkout's HEAD at assembly time.
    public let commit: String
    /// When that commit was authored, for the "how long have I been behind" clause.
    public let commitAt: Date?
    /// Whether `apps/native` had uncommitted changes when the bundle was made. Said
    /// out loud in the detail, never a warning on its own: building from a dirty tree
    /// is what working on the app looks like.
    public let dirty: Bool
    /// When the bundle was assembled.
    public let bundledAt: Date?

    public init(sourceRoot: String, commit: String, commitAt: Date?, dirty: Bool, bundledAt: Date?) {
        self.sourceRoot = sourceRoot
        self.commit = commit
        self.commitAt = commitAt
        self.dirty = dirty
        self.bundledAt = bundledAt
    }

    /// Decode the keys `scripts/source-stamp.sh` writes. Both the root and the commit
    /// are required: without either there is nothing to compare, and a half-stamp must
    /// not produce a confident answer.
    public init?(info: [String: Any]?) {
        guard let info,
              let root = Self.string(info["JuancodeSourceRoot"]),
              let commit = Self.string(info["JuancodeSourceCommit"]) else { return nil }
        self.sourceRoot = root
        self.commit = commit
        self.commitAt = Self.seconds(info["JuancodeSourceCommitAt"])
        self.dirty = (info["JuancodeSourceDirty"] as? Bool) ?? false
        self.bundledAt = Self.seconds(info["JuancodeBundledAt"])
    }

    /// The stamp of the bundle this process is running out of.
    public static var current: AppBuildStamp? { AppBuildStamp(info: Bundle.main.infoDictionary) }

    public var shortCommit: String { String(commit.prefix(7)) }

    private static func string(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Unix seconds, written as a string because that is what a shell heredoc can
    /// produce without a plist library.
    private static func seconds(_ raw: Any?) -> Date? {
        guard let s = raw as? String, let v = TimeInterval(s), v > 0 else { return nil }
        return Date(timeIntervalSince1970: v)
    }
}

/// How far one ref has moved past the commit the running app was built from.
public struct CheckoutDrift: Sendable, Equatable {
    /// `HEAD`, or an upstream such as `origin/main`.
    public let ref: String
    /// Commits in `ref` that are not in the built commit. Zero means this ref is the
    /// build.
    public let commits: Int
    /// When `ref`'s tip was committed, when git could say.
    public let tipCommittedAt: Date?

    public init(ref: String, commits: Int, tipCommittedAt: Date?) {
        self.ref = ref
        self.commits = commits
        self.tipCommittedAt = tipCommittedAt
    }

    /// Whether this ref is the local working checkout rather than a remote-tracking
    /// one. It decides the instruction: rebuild, or pull first.
    public var isLocal: Bool { ref == "HEAD" }
}

/// One thing that is wrong with the BUILD you are looking at. Shaped like
/// `DaemonWarning` on purpose — the same yellow row renders both, because "the core
/// is old" and "the app is old" are the same class of problem to the reader.
public struct AppBuildWarning: Sendable, Equatable {
    /// Short enough for a badge tooltip.
    public let headline: String
    /// The sentence that says what to do about it.
    public let detail: String

    public init(headline: String, detail: String) {
        self.headline = headline
        self.detail = detail
    }
}

/// Turning a stamp plus git's answers into "say something" or "stay quiet".
public enum AppStaleness {
    /// You are one commit behind the moment you commit, and two while a sibling agent
    /// lands something. Below this many, say nothing — an indicator that is always on
    /// is an indicator nobody reads.
    public static let quietBelowCommits = 3

    /// ...unless the drift has lasted. One commit from yesterday morning is not the
    /// same fact as one commit from a minute ago, and the case this file exists for
    /// was fourteen hours old.
    public static let quietBelowAge: TimeInterval = 6 * 3600

    /// The worst drift worth saying out loud, or nil when the build is current enough.
    ///
    /// `now` is injected so the age rule is testable without waiting six hours.
    public static func warning(stamp: AppBuildStamp, drifts: [CheckoutDrift],
                               now: Date = Date()) -> AppBuildWarning? {
        // The ref that has moved furthest wins, and a tie goes to the local checkout:
        // when both say the same number the actionable one is "rebuild", not "pull".
        guard let worst = drifts.filter({ $0.commits > 0 })
            .max(by: { ($0.commits, $0.isLocal ? 1 : 0) < ($1.commits, $1.isLocal ? 1 : 0) })
        else { return nil }

        let age = age(of: worst, stamp: stamp, now: now)
        guard worst.commits >= quietBelowCommits || (age ?? 0) >= quietBelowAge else { return nil }

        let plural = worst.commits == 1 ? "commit" : "commits"
        let target = worst.isLocal ? "the checkout" : worst.ref
        var detail = "This app was built from \(stamp.shortCommit)"
        if let commitAt = stamp.commitAt { detail += " (\(clock.string(from: commitAt)))" }
        detail += " in \(stamp.sourceRoot), and \(target) has \(worst.commits) \(plural) it does not have"
        if let hours = age.map({ Int($0 / 3600) }), hours >= 1 {
            detail += ", the newest of them \(hours)h newer than this build"
        }
        detail += ". Nothing that landed since then is in the window you are looking at"
        detail += stamp.dirty ? " (and it was built from a dirty tree). " : ". "
        detail += worst.isLocal
            ? "`apps/native/scripts/dev-app.sh` rebuilds the bundle and relaunches it — "
                + "`swift build` alone does not refresh the .app, and the .app is what the "
                + "Dock launches."
            : "`git pull` in that checkout first, then relaunch with "
                + "`apps/native/scripts/dev-app.sh` — pulling alone changes nothing on screen."

        return AppBuildWarning(
            headline: "this app is \(worst.commits) \(plural) behind \(target)",
            detail: detail)
    }

    /// How long the app has been behind: the gap between the commit it was built from
    /// and the tip it is behind. Falls back to the age of the build itself when git
    /// could not date the tip, and is nil when neither date is known.
    private static func age(of drift: CheckoutDrift, stamp: AppBuildStamp, now: Date) -> TimeInterval? {
        if let tip = drift.tipCommittedAt, let built = stamp.commitAt {
            return max(0, tip.timeIntervalSince(built))
        }
        guard let built = stamp.commitAt ?? stamp.bundledAt else { return nil }
        return max(0, now.timeIntervalSince(built))
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()
}

/// Asking a checkout how far it has moved.
///
/// `git` is injected as a closure so every rule above is tested against fixed answers
/// instead of a real repository — and so the live version can be the only thing that
/// knows about `ProcessRunner`.
public enum CheckoutProbe {
    /// Run `git <args>` in the stamped checkout; nil for any non-zero exit, which is
    /// how "this ref does not exist" and "this is not a repo any more" both arrive.
    public typealias Git = @Sendable ([String]) async -> String?

    /// The refs worth comparing against, and how far each has moved.
    ///
    /// Both matter and for different reasons: HEAD catches "I pulled and forgot to
    /// rebuild", the upstream catches "I never pulled" — which is the one that cost a
    /// day, because that checkout was 17 commits behind origin/main while its own HEAD
    /// was 2 commits past the build.
    ///
    /// No fetch. The upstream ref is whatever the last pull left in `.git`, and on this
    /// machine sibling worktrees share those refs and keep them current for free. A
    /// fetch from the app would cost ~2s of network on every check to tell us something
    /// we almost always already know (juancode-session-start-cost).
    public static func drifts(stamp: AppBuildStamp, git: Git) async -> [CheckoutDrift] {
        var refs = ["HEAD"]
        if let upstream = await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]),
           !upstream.isEmpty {
            refs.append(upstream)
        }
        var found: [CheckoutDrift] = []
        for ref in refs {
            // `count` is the number of commits in ref that the build does not have.
            // A failure here is a commit git has never heard of — a rebase, or a
            // bundle from another clone — and that is "unknown", never "behind".
            guard let raw = await git(["rev-list", "--count", "\(stamp.commit)..\(ref)"]),
                  let commits = Int(raw) else { continue }
            let tip = await git(["log", "-1", "--format=%ct", ref])
                .flatMap { TimeInterval($0) }
                .map { Date(timeIntervalSince1970: $0) }
            found.append(CheckoutDrift(ref: ref, commits: commits, tipCommittedAt: tip))
        }
        return found
    }

    /// The live runner: git in the stamped checkout, with the app's environment
    /// inherited verbatim like every other shell-out here.
    public static func git(in root: String) -> Git {
        { args in
            guard let result = try? await ProcessRunner.capture("git", ["-C", root] + args, timeout: 10),
                  result.ok else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// The app's answer to "am I what the checkout would build", cached.
///
/// An actor with a floor on how often it re-asks, because the probe is four `git`
/// execs and fork+exec costs ~257ms each on this machine (exec-costs-257ms). Once at
/// launch and again when someone opens the badge is the whole budget.
public actor AppBuildDrift {
    public static let shared = AppBuildDrift()

    private var cached: AppBuildWarning?
    private var checkedAt: Date?

    public init() {}

    /// The current warning, re-measuring at most once per `minInterval`.
    ///
    /// Returns nil — quietly and immediately — for an unstamped build. A bare
    /// `swift run` has no bundle, and shouting "cannot verify" at the one workflow
    /// that never has a stamp is the nagging this is meant to avoid.
    public func warning(stamp: AppBuildStamp? = .current,
                        minInterval: TimeInterval = 300,
                        now: Date = Date()) async -> AppBuildWarning? {
        guard let stamp else { return nil }
        if let checkedAt, now.timeIntervalSince(checkedAt) < minInterval { return cached }
        let drifts = await CheckoutProbe.drifts(stamp: stamp, git: CheckoutProbe.git(in: stamp.sourceRoot))
        let warning = AppStaleness.warning(stamp: stamp, drifts: drifts, now: now)
        if warning != cached, let warning {
            NSLog("juancode: \(warning.headline). \(warning.detail)")
        }
        cached = warning
        checkedAt = now
        return warning
    }
}
