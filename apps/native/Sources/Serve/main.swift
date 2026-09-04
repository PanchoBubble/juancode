import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServer

// Headless runner for port 4280 — the one address the oracle sidecar and every
// other remote client know — with no GUI in play.
//
// Two modes, because 4280 means two different things depending on which core owns
// the ptys:
//
//   swift (default)  boots the real session registry + SQLite store + WS/HTTP
//                    server in this process (juancode-u34.3). The SwiftUI shell
//                    (u34.4) embeds the same server.
//   rust             connects to the `juancoded` daemon and runs the same relay
//                    the shell boots for a rust launch (juancode-eko6), so the
//                    sidecar keeps working with the desktop closed.
//
// Pick with `--core rust`, else `JUANCODE_CORE`.

let host = Config.bindHost
let mode: ServeMode

do {
    mode = try ServeMode.resolve(arguments: CommandLine.arguments)
} catch {
    logLine((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    exit(2)
}

switch mode {
case .rust:
    do {
        try await RustServe.run(host: host, port: Config.port)
    } catch {
        logLine((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        exit(1)
    }

case .swift:
    let state = try AppState()

    // Serve the built web app if present (apps/web/dist), resolved relative to cwd.
    let webDist = (FileManager.default.currentDirectoryPath as NSString)
        .appendingPathComponent("../web/dist")

    print("juancode-serve listening on http://\(host):\(Config.port)")

    try await JuancodeServer.run(
        state: state,
        host: host,
        port: Config.port,
        webDist: FileManager.default.fileExists(atPath: webDist) ? webDist : nil
    )
}
