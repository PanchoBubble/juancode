import Foundation
import JuancodeCore

/// The persisted "which core" preference, and the launch-time resolution of it.
///
/// Same shape as the terminal-backend precedent (`TerminalBackend`): a
/// `UserDefaults` key the Settings pane writes, with a `JUANCODE_*` environment
/// variable that wins over it. The difference is that a terminal surface can be
/// swapped mid-flight and a core cannot, so this is read exactly once per launch
/// and flipping it prompts for a relaunch instead of taking effect.
public enum CoreBackendPreference {
    /// Namespaced like the other juancode defaults keys.
    public static let defaultsKey = "juancode.core.backend"

    /// The core the next launch will use, absent an env override. Defaults to
    /// `swift`: the Rust core is not at parity, so it is opt-in.
    public static var persisted: CoreBackend {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let backend = CoreBackend(rawValue: raw) else { return .swift }
        return backend
    }

    /// Record the choice for the next launch. This is all the setter does: nothing
    /// about the current launch changes, which is why the UI asks to relaunch.
    public static func setPersisted(_ backend: CoreBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: defaultsKey)
    }
}

/// Which core a launch asked for, which one it got, and why they might differ.
/// Carried by the app model so the badge, the Settings pane and any bug report all
/// read the same answer.
public struct CoreSelection: Sendable, Equatable {
    /// Where the choice came from, so the Settings pane can say "pinned by
    /// JUANCODE_CORE" instead of showing a picker that would not be obeyed.
    public enum Source: String, Sendable {
        case environment
        case setting
        case fallbackDefault
    }

    /// What this launch asked for.
    public let requested: CoreBackend
    /// What it is actually running on. Differs from `requested` only after a
    /// fallback.
    public let active: CoreBackend
    public let source: Source
    /// Why the requested core could not be used, nil when it was.
    public let unreachableReason: String?
    /// The sqlite file the active core's rows live in.
    public let databasePath: String
    /// Where the Rust daemon was looked for, shown whether or not it answered.
    public let rustCoreURL: String

    public init(requested: CoreBackend, active: CoreBackend, source: Source,
                unreachableReason: String?, databasePath: String, rustCoreURL: String) {
        self.requested = requested
        self.active = active
        self.source = source
        self.unreachableReason = unreachableReason
        self.databasePath = databasePath
        self.rustCoreURL = rustCoreURL
    }

    public var didFallBack: Bool { requested != active }

    /// Whether the user's picker can change anything, or an env var has pinned it.
    public var isPinnedByEnvironment: Bool { source == .environment }

    /// Resolve what a launch should try, without building anything.
    public static func resolve(persisted: CoreBackend = CoreBackendPreference.persisted,
                               override: CoreBackend? = Config.coreBackendOverride)
        -> (requested: CoreBackend, source: Source) {
        if let override { return (override, .environment) }
        return (persisted, .setting)
    }
}

/// A booted core plus everything the UI needs to explain it.
public struct BootedCore: Sendable {
    public let client: any CoreClient
    public let selection: CoreSelection
    /// Non-nil when the on-disk database would not open and an in-memory store was
    /// substituted for this launch (the pre-existing `SwiftCoreClient` degradation).
    public let degradedReason: String?
    /// The database file the degraded launch was trying to open, for the recovery UI.
    public let corruptDbPath: String

    public init(client: any CoreClient, selection: CoreSelection,
                degradedReason: String?, corruptDbPath: String) {
        self.client = client
        self.selection = selection
        self.degradedReason = degradedReason
        self.corruptDbPath = corruptDbPath
    }
}

/// Picks the core for a launch: the one place that turns a preference plus an
/// environment override into a live `CoreClient`.
public enum CoreBoot {
    /// Build the core this launch drives.
    ///
    /// The rust path fails LOUDLY and falls back: when the daemon does not answer
    /// the handshake, the reason is carried on the returned selection so the UI can
    /// say what happened and offer the fallback it already took, rather than
    /// leaving a window that looks fine and does nothing. Both builders are
    /// injectable so the selection logic can be tested without a database or a
    /// socket.
    public static func boot(
        persisted: CoreBackend = CoreBackendPreference.persisted,
        override: CoreBackend? = Config.coreBackendOverride,
        rustCoreURL: String = Config.rustCoreBaseURL,
        makeSwift: (String) -> (core: any CoreClient, degradedReason: String?) = { path in
            let built = SwiftCoreClient.local(dbPath: path)
            return (built.core, built.degradedReason)
        },
        makeRust: (String) throws -> any CoreClient = { url in
            try RustCoreClient.connect(baseURL: url)
        }
    ) -> BootedCore {
        let (requested, source) = CoreSelection.resolve(persisted: persisted, override: override)
        if requested == .rust {
            do {
                let client = try makeRust(rustCoreURL)
                return BootedCore(
                    client: client,
                    selection: CoreSelection(requested: .rust, active: .rust, source: source,
                                             unreachableReason: nil,
                                             databasePath: Config.databasePath(for: .rust),
                                             rustCoreURL: rustCoreURL),
                    degradedReason: nil,
                    corruptDbPath: Config.databasePath(for: .rust))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                NSLog("juancode: JUANCODE_CORE=rust selected but the daemon is not usable: \(reason)")
                let path = Config.databasePath(for: .swift)
                let built = makeSwift(path)
                return BootedCore(
                    client: built.core,
                    selection: CoreSelection(requested: .rust, active: .swift, source: source,
                                             unreachableReason: reason,
                                             databasePath: path, rustCoreURL: rustCoreURL),
                    degradedReason: built.degradedReason,
                    corruptDbPath: path)
            }
        }
        let path = Config.databasePath(for: .swift)
        let built = makeSwift(path)
        return BootedCore(
            client: built.core,
            selection: CoreSelection(requested: .swift, active: .swift, source: source,
                                     unreachableReason: nil,
                                     databasePath: path, rustCoreURL: rustCoreURL),
            degradedReason: built.degradedReason,
            corruptDbPath: path)
    }
}
