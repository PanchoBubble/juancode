import Foundation
import JuancodeCore

/// What this launch connected to, and everything the UI needs to explain it.
///
/// There used to be a choice here — a persisted `juancode.core.backend`, a
/// `JUANCODE_CORE` override that won over it, a requested-vs-active pair and a
/// fallback to the in-process Swift core when the daemon did not answer. The Swift
/// core is gone (juancode-nqpm), so all of that collapses to one fact: which
/// daemon answered, and what is wrong with it.
///
/// The fields that remain are the ones a screenshot in a bug report has to carry.
/// A daemon is a separate process with its own build and its own lifetime, so
/// "which one answered" is still a real question even when there is only one kind
/// of core left.
public struct CoreSelection: Sendable, Equatable {
    /// The desktop-side mirror of the daemon's session rows.
    public let databasePath: String
    /// Where the daemon was found.
    public let rustCoreURL: String
    /// Who answered. Nil on a daemon too old to identify itself.
    public let daemon: DaemonIdentity?
    /// Everything wrong with the daemon that answered, worst first. Empty is the
    /// normal case and the only one that needs no explaining.
    ///
    /// A stale daemon is NOT a boot failure: it owns live ptys, and refusing to
    /// connect would end somebody's running sessions to fix a reporting problem.
    public let daemonWarnings: [DaemonWarning]

    public init(databasePath: String, rustCoreURL: String,
                daemon: DaemonIdentity? = nil, daemonWarnings: [DaemonWarning] = []) {
        self.databasePath = databasePath
        self.rustCoreURL = rustCoreURL
        self.daemon = daemon
        self.daemonWarnings = daemonWarnings
    }

    /// Whether the core that answered is not the one this checkout would have built.
    public var daemonIsStale: Bool { !daemonWarnings.isEmpty }

    /// Whether live sessions are still there after this app quits, and what keeps
    /// them. Nil when the daemon does not say.
    ///
    /// NOT a warning, and deliberately not carried in `daemonWarnings`: that array is
    /// what turns the core badge yellow, and a stated mode working as asked is not a
    /// fault. The two do stack, though, and that is the point — a persistent daemon
    /// that has gone stale is both persistent and loud.
    public var sessionPersistence: String? { daemon?.persistence }
}

/// A connected core plus everything the UI needs to explain it.
public struct BootedCore: Sendable {
    public let client: any CoreClient
    public let selection: CoreSelection

    public init(client: any CoreClient, selection: CoreSelection) {
        self.client = client
        self.selection = selection
    }
}

/// Connects the launch to the `juancoded` daemon: the one place that names a
/// concrete `CoreClient`.
public enum CoreBoot {
    /// Connect, or throw with the daemon's own reason.
    ///
    /// It throws rather than degrading because there is nothing left to degrade to.
    /// A launch that cannot reach the daemon has no ptys, no session rows and no
    /// history; the caller's job is to say so and offer to retry, not to open a
    /// window that looks fine and does nothing. `makeRust` is injectable so the
    /// selection logic can be tested without a socket.
    public static func connect(
        rustCoreURL: String = Config.rustCoreBaseURL,
        makeRust: (String) throws -> any CoreClient = { url in
            try RustCoreClient.connect(baseURL: url)
        },
        appIdentity: AppIdentity = .current
    ) throws -> BootedCore {
        let client = try makeRust(rustCoreURL)
        // Asked and answered at boot, not on demand: the daemon's build stamp is what
        // it was when IT started, and the whole comparison is against that. Deferring
        // it would leave the first, most misleading session list on screen unlabelled.
        let daemon = client.info.daemon
        let warnings = daemon?.warnings(against: appIdentity) ?? []
        for warning in warnings {
            NSLog("juancode: core at \(rustCoreURL) — \(warning.headline). \(warning.detail)")
        }
        return BootedCore(
            client: client,
            selection: CoreSelection(databasePath: Config.mirrorDatabasePath,
                                     rustCoreURL: rustCoreURL,
                                     daemon: daemon, daemonWarnings: warnings))
    }
}
