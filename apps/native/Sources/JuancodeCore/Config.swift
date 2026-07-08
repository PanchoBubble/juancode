import Foundation

/// Runtime configuration, mirroring `apps/server/src/config.ts`. Reads the same
/// `JUANCODE_*` environment overrides so the native app and the Node server can
/// share a data dir / port convention.
public enum Config {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Port the embedded HTTP+WS server listens on (`JUANCODE_PORT`, default 4280).
    public static var port: Int {
        env["JUANCODE_PORT"].flatMap(Int.init) ?? 4280
    }

    /// Host the embedded server binds to (`JUANCODE_HOST`, default `127.0.0.1`).
    ///
    /// Loopback is the secure default: the server is reachable only from this Mac,
    /// so the natural way to expose it remotely is a Cloudflare Tunnel / Tailscale
    /// that connects out *from* the machine to a `127.0.0.1` origin — no inbound
    /// port, nothing on the LAN. Override with `JUANCODE_HOST` when you deliberately
    /// want LAN reachability (e.g. `0.0.0.0`) — only do so behind a fronting auth
    /// layer (e.g. Cloudflare Access), since the server then accepts network traffic.
    public static var bindHost: String {
        let h = (env["JUANCODE_HOST"] ?? "").trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? "127.0.0.1" : h
    }

    /// Where the sqlite database lives (`JUANCODE_DATA_DIR`, default `./data`).
    public static var dataDir: String {
        env["JUANCODE_DATA_DIR"] ?? (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent("data")
    }

    /// Max bytes of terminal output retained (and persisted) per session for
    /// replay on (re)attach (`JUANCODE_SCROLLBACK`, default 256 KiB).
    public static var scrollbackLimit: Int {
        env["JUANCODE_SCROLLBACK"].flatMap(Int.init) ?? 256 * 1024
    }

    /// Max persisted sessions kept per project (worktrees folded into their repo,
    /// see `projectCwd`). Older sessions beyond the cap are hard-deleted at startup
    /// and on each new session (`JUANCODE_SESSIONS_PER_PROJECT`, default 20). A
    /// value ≤ 0 disables the cap.
    public static var sessionsPerProjectCap: Int {
        env["JUANCODE_SESSIONS_PER_PROJECT"].flatMap(Int.init) ?? 20
    }

    /// Root the directory picker opens at. Prefers `JUANCODE_DEFAULT_CWD`, then
    /// `~/workdir` if present, else the home directory.
    public static var defaultCwd: String {
        if let override = env["JUANCODE_DEFAULT_CWD"], !override.isEmpty { return override }
        let home = NSHomeDirectory()
        let workdir = (home as NSString).appendingPathComponent("workdir")
        return FileManager.default.fileExists(atPath: workdir) ? workdir : home
    }

    /// Root under which sidebar folders must live to be shown. Same resolution as
    /// `defaultCwd` (`JUANCODE_DEFAULT_CWD`, then `~/workdir`, else home) — folders
    /// outside it are filtered out as noise. `~/workdir` covers `<repo>-worktrees/…`
    /// siblings too, so worktrees of in-workspace repos stay visible.
    public static var workspaceRoot: String { defaultCwd }

    /// Whether `path` lives at or under `workspaceRoot`, normalised so a folder
    /// isn't matched by a sibling that merely shares a name prefix.
    public static func isUnderWorkspaceRoot(_ path: String) -> Bool {
        let root = (workspaceRoot as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        return p == root || p.hasPrefix(root + "/")
    }

    /// How long a session must be verifiably idle before the reaper kills its CLI
    /// process tree to free RAM, leaving a dormant, resumable tile (juancode-lgq).
    /// `JUANCODE_REAP_IDLE_MINUTES`, default 30; a value ≤ 0 disables reaping.
    public static var reapIdleMinutes: Int {
        env["JUANCODE_REAP_IDLE_MINUTES"].flatMap(Int.init) ?? 30
    }
}
