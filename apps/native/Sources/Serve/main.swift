import Foundation
import JuancodeCore

// Headless runner for port 4280 — the one address the oracle sidecar and every
// other remote client know — with no GUI in play.
//
// It connects to the `juancoded` daemon and runs the same relay the SwiftUI shell
// boots (juancode-eko6), so the sidecar keeps working with the desktop closed.
//
// There used to be a `--core swift|rust` flag here, because 4280 meant two
// different things depending on which core owned the ptys. The daemon owns them
// now, always: juancode-nqpm deleted the in-process core, and with it the choice.

do {
    try await RustServe.run(host: Config.bindHost, port: Config.port)
} catch {
    logLine((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    exit(1)
}
