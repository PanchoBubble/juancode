import Foundation
import JuancodeClient
import JuancodeCore
import JuancodeServer

/// Serve port 4280 for the Rust core with no GUI (juancode-eko6).
///
/// `juancode-bse5` put the 4280 relay inside the SwiftUI app, which covers
/// desktop-up + daemon-up. It does not cover desktop-DOWN + daemon-up: the daemon
/// keeps running ptys and keeps broadcasting `activity`, but nothing answers 4280,
/// so the oracle sidecar has no notifications, no steering and no dispatch until
/// somebody relaunches the desktop. This is the same relay, booted from a headless
/// process instead.
///
/// Nothing here is a second implementation of the relay: it builds the same
/// `CoreProxyServer.Source` over a `RustCoreClient` that `startProxyServer` builds.
/// It calls `CoreProxyServer.run` directly rather than going through
/// `RustCoreClient.startProxyServer`, for one reason: that method is best-effort by
/// design (it detaches a `Task` and turns a bind failure into an `NSLog`), which is
/// right for a GUI whose local shell still works with 4280 taken, and wrong for a
/// process whose entire job is that port. Here the failure has to reach the exit
/// code.
enum RustServe {
    /// How long to keep trying the daemon before giving up, in seconds.
    /// `JUANCODE_SERVE_WAIT_SECONDS`, default 0 — fail on the first miss.
    ///
    /// Zero is the default because the useful supervisor shapes both want it: a
    /// LaunchAgent with `KeepAlive` restarts a runner that exits, and a human
    /// running this in a terminal wants to be told the daemon is down, not left
    /// staring at a process that has not said anything. Raise it when the runner is
    /// started in the same breath as `juancoded` and may win the race.
    static var waitForCoreSeconds: Int {
        ProcessInfo.processInfo.environment["JUANCODE_SERVE_WAIT_SECONDS"].flatMap(Int.init) ?? 0
    }

    /// Seconds between connection attempts while waiting. Matches the reconnect
    /// delay `WireConnection` uses once the socket has been up, so the runner
    /// retries at the same cadence before and after.
    private static let retryDelaySeconds = 3

    static func run(host: String, port: Int) async throws {
        let upstream = Config.rustCoreBaseURL
        let client = try await connect(upstream: upstream)

        // The socket dropping is not a reason to exit — the daemon restarting is the
        // common case and `WireConnection` retries every 3s — but it IS a reason to
        // say so. A relay that goes quiet with nothing in the log is the failure mode
        // this ticket is about.
        //
        // Edges only. `WireConnection` reports a fresh failure on every retry, and
        // this process is meant to run for weeks: logging each one turns a daemon
        // that is down overnight into ~1200 identical lines an hour, which buries
        // the transition that actually mattered.
        let state = ConnectionLog()
        client.onConnectionChange { up, reason in
            guard let line = state.line(up: up, reason: reason, upstream: upstream,
                                        retryDelaySeconds: retryDelaySeconds) else { return }
            logLine(line)
        }

        let source = CoreProxyServer.Source(
            sessions: { client.sessions() },
            session: { client.session($0) },
            searchSessions: { client.searchSessions($0, limit: $1) },
            kill: { client.kill($0) },
            deleteSession: { client.deleteSession($0) },
            backendName: CoreBackend.rust.rawValue)

        // Intent, not confirmation: the bind happens inside `run`, and Hummingbird
        // prints its own "Server started and listening on …" once it has succeeded.
        // Claiming to be listening here would be a lie on the port-taken path, which
        // is the likeliest way this process fails on a machine that also runs the
        // desktop app.
        print("juancode-serve binding http://\(host):\(port) "
            + "(core: rust, relaying /ws to \(upstream))")

        // `handleSignals: true` matches the swift path: a headless runner owns its
        // own lifecycle and should shut down on SIGINT/SIGTERM rather than be killed.
        try await CoreProxyServer.run(source: source, upstreamBaseURL: upstream,
                                      host: host, port: port, handleSignals: true)

        // `run` returning at all means the server stopped without throwing — a
        // graceful shutdown, or something that ended the service quietly. Either way
        // this process's job is over, and saying so beats a silent exit 0 that reads
        // like it is still up.
        logLine("relay stopped serving \(host):\(port)")
    }

    /// Connect to the daemon, optionally waiting for it to appear.
    ///
    /// Deliberately does NOT fall back to the swift core the way `CoreBoot` does.
    /// The app falls back because a window that does nothing is worse than a window
    /// on the other core; a relay has the opposite problem. Falling back here would
    /// leave 4280 answering `/api/sessions` from a *different* database and `/ws`
    /// from a registry with no ptys in it, and the sidecar has no way to tell that
    /// apart from the daemon's sessions having vanished.
    private static func connect(upstream: String) async throws -> RustCoreClient {
        let deadline = Date().addingTimeInterval(TimeInterval(waitForCoreSeconds))
        var lastError: Error?
        repeat {
            do {
                return try RustCoreClient.connect(baseURL: upstream)
            } catch {
                lastError = error
                guard Date() < deadline else { break }
                logLine("\(reason(for: error)) — retrying in \(retryDelaySeconds)s")
                await Nap.duration(.seconds(retryDelaySeconds))
            }
        } while Date() < deadline
        throw DaemonUnreachable(upstream: upstream,
                                waited: waitForCoreSeconds,
                                reason: lastError.map(reason(for:)) ?? "no reason given")
    }

    private static func reason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// The daemon was not there. Loud on purpose: this is the whole reason the runner
/// exists, so it exits non-zero with the URL it tried and how long it waited.
struct DaemonUnreachable: LocalizedError {
    let upstream: String
    let waited: Int
    let reason: String

    var errorDescription: String? {
        let waitedFor = waited > 0 ? " after waiting \(waited)s" : ""
        return "the rust core at \(upstream) is not usable\(waitedFor): \(reason). "
            + "Start juancoded, or set JUANCODE_SERVE_WAIT_SECONDS to wait for it."
    }
}

/// Turns the connection callback's every-retry stream into one line per edge.
///
/// The reason is kept alongside the state: two consecutive failures with different
/// reasons ("socket is not connected" as the daemon dies, then "could not connect"
/// once it is gone) are the same outage, and only the first is worth a line.
final class ConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUp: Bool?
    private var downSince: Date?

    func line(up: Bool, reason: String?, upstream: String, retryDelaySeconds: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard up != lastUp else { return nil }
        lastUp = up
        if up {
            let outage = downSince.map { " after \(Int(Date().timeIntervalSince($0)))s down" } ?? ""
            downSince = nil
            return "daemon connection up (\(upstream))\(outage)"
        }
        downSince = Date()
        return "daemon connection down: \(reason ?? "no reason given"). "
            + "Retrying every \(retryDelaySeconds)s; the relay stays on this port and "
            + "REST reads keep answering from the mirror."
    }
}
