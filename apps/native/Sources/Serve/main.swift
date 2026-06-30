import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServer

// Headless runner for the embedded server (juancode-u34.3): boots the real
// session registry + SQLite store + WS/HTTP server without the GUI, so apps/web
// can drive the native backend. The SwiftUI shell (u34.4) embeds the same server.

let state = try AppState()
let host = Config.bindHost

// Serve the built web app if present (apps/web/dist), resolved relative to cwd.
let webDist = (FileManager.default.currentDirectoryPath as NSString)
    .appendingPathComponent("../web/dist")

let auth = AuthConfig(token: Config.remoteToken)
print("juancode-serve listening on http://\(host):\(Config.port)")
print(auth.isEnabled
    ? "  auth: ENABLED — token required on HTTP + WS"
    : "  auth: disabled (set JUANCODE_TOKEN, or call ensureRemoteToken, to require a token for remote access)")

try await JuancodeServer.run(
    state: state,
    host: host,
    port: Config.port,
    webDist: FileManager.default.fileExists(atPath: webDist) ? webDist : nil,
    auth: auth
)
