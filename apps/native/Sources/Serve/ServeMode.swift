import Foundation
import JuancodeCore

/// Which core `juancode-serve` fronts for this run.
///
/// The headless runner exists so a machine can answer port 4280 with no GUI, and
/// there are two different ways to do that depending on who owns the ptys:
///
///   - `.swift` boots the whole in-process server (`AppState` + `JuancodeServer`),
///     the original behaviour of this binary.
///   - `.rust` connects to the `juancoded` daemon and runs `CoreProxyServer`, the
///     same relay the SwiftUI app boots when `JUANCODE_CORE=rust`. The daemon owns
///     the ptys, so `/ws` is relayed to it and the REST session reads come off the
///     desktop mirror.
enum ServeMode: String {
    case swift
    case rust

    /// `--core swift|rust` on the command line, else `JUANCODE_CORE`, else swift.
    ///
    /// The flag wins over the environment on purpose: `JUANCODE_CORE` is commonly
    /// exported for a shell session, and a runner started from that shell with an
    /// explicit flag should serve what the flag says. An unrecognised value is
    /// fatal here rather than ignored (as `Config.coreBackendOverride` does for the
    /// app): a typo that silently serves the wrong core's sessions is worse than a
    /// runner that refuses to start.
    static func resolve(arguments: [String],
                        environmentOverride: CoreBackend? = Config.coreBackendOverride) throws -> ServeMode {
        if let raw = flagValue(in: arguments) {
            guard let mode = ServeMode(rawValue: raw.lowercased()) else {
                throw ServeUsageError(message: "unknown --core \(raw), expected swift or rust")
            }
            return mode
        }
        guard let environmentOverride else { return .swift }
        return environmentOverride == .rust ? .rust : .swift
    }

    /// Accepts both `--core rust` and `--core=rust`.
    private static func flagValue(in arguments: [String]) -> String? {
        for (index, arg) in arguments.enumerated() {
            if arg == "--core" {
                return index + 1 < arguments.count ? arguments[index + 1] : ""
            }
            if arg.hasPrefix("--core=") {
                return String(arg.dropFirst("--core=".count))
            }
        }
        return nil
    }
}

struct ServeUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One line on stderr, so the two streams stay separable when this runs under a
/// supervisor: stdout is the "listening on …" banner, stderr is everything that
/// went wrong or changed underneath.
func logLine(_ text: String) {
    FileHandle.standardError.write(Data("juancode-serve: \(text)\n".utf8))
}
