import Foundation

/// A per-spawn instruction set, resolved before any argv is built.
///
/// The three CLIs expose nothing in common here, so one preset name means three
/// mechanisms and each provider needs a different half of this:
///
/// - claude takes the **body**, through `--append-system-prompt`. It is the only true
///   append, and the only one where juancode supplies the prose.
/// - codex takes the **name**, through `--profile <name>`, which layers
///   `$CODEX_HOME/<name>.config.toml` — a file the user wrote.
/// - opencode takes the **name**, through `--agent <name>`, naming an agent the user
///   defined in their own config.
///
/// That asymmetry is deliberate and is what keeps this inside the prime directive: for
/// the two CLIs that own the concept we select what the user already configured, and we
/// never author a CLI's config. Only claude, which has no such concept, gets prose from
/// us — through a flag built for exactly that.
///
/// Resolved eagerly so `ProviderSpec.startArgs` stays a pure function of its inputs.
public struct Preset: Sendable, Equatable {
    /// The name the client asked for, already validated by `PresetStore`.
    public let name: String
    /// The prose behind the name. Non-nil only for the provider that needs it
    /// (claude); the other two are selecting a definition the user owns, so there is
    /// nothing for us to read.
    public let body: String?

    public init(name: String, body: String?) {
        self.name = name
        self.body = body
    }
}

/// Why a preset name could not become a `Preset`.
public enum PresetError: Error, Equatable, CustomStringConvertible {
    case badName(String)
    case noBody(name: String, path: String)
    case tooLarge(name: String, bytes: Int, limit: Int)

    public var description: String {
        switch self {
        case .badName(let name):
            return "preset name \"\(name)\" is not allowed: use letters, digits, "
                + "'-' or '_', starting with a letter or digit, at most 64 characters"
        case .noBody(let name, let path):
            return "preset \"\(name)\" has no body: expected a file at \(path)"
        case .tooLarge(let name, let bytes, let limit):
            return "preset \"\(name)\" is \(bytes) bytes, over the \(limit)-byte limit"
        }
    }
}

/// Resolves a `create.preset` name against juancode's own preset directory.
///
/// The directory is ours, not a CLI's: `~/.juancode/presets` beside the data dir, or
/// `<JUANCODE_DATA_DIR>/presets` when that is relocated, overridable outright with
/// `JUANCODE_PRESET_DIR`. Nothing here reads or writes a provider's config.
public enum PresetStore {
    /// Bodies ride in the CLI's argv, which is bounded (`ARG_MAX`). A prompt this long
    /// is a file the user meant to pass some other way, and a clear refusal beats an
    /// `E2BIG` from `execve` that surfaces as a session that would not start.
    public static let bodyLimit = 32 * 1024

    /// Names go into both a filesystem path and an argv slot, so the allowlist is the
    /// validation rather than escaping. It rejects `..` and `/` (traversal out of the
    /// preset directory) and a leading `-` (which the CLI would read as a flag).
    static let nameHead = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    static let nameTail = nameHead.union(["-", "_"])
    static let nameLimit = 64

    /// `getenv` rather than `ProcessInfo.processInfo.environment`, which snapshots the
    /// environment on first access and so never sees a later `setenv`. Nothing in the
    /// app changes these at runtime, so the two agree in production — but a test that
    /// points the store at its own directory has no other way to be believed.
    private static func envValue(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    public static var directory: String {
        if let override = envValue("JUANCODE_PRESET_DIR") { return override }
        if let dataDir = envValue("JUANCODE_DATA_DIR") {
            return (dataDir as NSString).appendingPathComponent("presets")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/presets")
    }

    public static func path(for name: String) -> String {
        (directory as NSString).appendingPathComponent("\(name).md")
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, name.count <= nameLimit else { return false }
        guard nameHead.contains(first) else { return false }
        return name.dropFirst().allSatisfy(nameTail.contains)
    }

    /// Resolve a name for one provider, or throw.
    ///
    /// Throwing rather than degrading to no preset on purpose: a preset the client asked
    /// for and the core quietly dropped is indistinguishable from one it applied, which
    /// is the same class of bug the `spawn-model` scenario exists to catch.
    public static func resolve(name: String, for provider: ProviderId) throws -> Preset {
        guard isValidName(name) else { throw PresetError.badName(name) }
        guard provider.presetNeedsBody else { return Preset(name: name, body: nil) }

        let file = path(for: name)
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw PresetError.noBody(name: name, path: file)
        }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PresetError.noBody(name: name, path: file) }
        let bytes = body.utf8.count
        guard bytes <= bodyLimit else {
            throw PresetError.tooLarge(name: name, bytes: bytes, limit: bodyLimit)
        }
        return Preset(name: name, body: body)
    }
}

extension ProviderId {
    /// Whether this provider's mechanism needs the preset's prose rather than its name.
    /// True only for claude: codex and opencode select a definition the user owns.
    var presetNeedsBody: Bool {
        switch self {
        case .claude: return true
        case .codex, .opencode: return false
        }
    }
}
