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

    /// Where the sqlite database lives. Defaults to `~/.juancode/data` so the store
    /// is stable no matter which directory the app is launched from; override with
    /// `JUANCODE_DATA_DIR`. (Previously `./data`, which silently used a different
    /// database per launch directory.)
    public static var dataDir: String {
        if let override = env["JUANCODE_DATA_DIR"], !override.isEmpty { return override }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/data")
    }

    /// Max bytes of terminal output retained (and persisted) per session for
    /// replay on (re)attach (`JUANCODE_SCROLLBACK`, default 256 KiB).
    public static var scrollbackLimit: Int {
        env["JUANCODE_SCROLLBACK"].flatMap(Int.init) ?? 256 * 1024
    }

    /// Max persisted sessions kept per project (worktrees folded into their repo,
    /// see `projectCwd`). Archived sessions don't count toward the cap and are never
    /// pruned. Older unarchived sessions beyond the cap are hard-deleted at startup
    /// and on each new session (`JUANCODE_SESSIONS_PER_PROJECT`, default 50). A
    /// value ≤ 0 disables the cap.
    public static var sessionsPerProjectCap: Int {
        env["JUANCODE_SESSIONS_PER_PROJECT"].flatMap(Int.init) ?? 50
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

    /// Seed a freshly-attached local terminal pane from the parsed headless model
    /// (a clean repaint via `SessionTerminalModel.seedBytes()`) instead of replaying
    /// the raw byte ring (juancode-a2h.2) — killing replay-garble and the synthetic
    /// alt-screen resync. On by default; set `JUANCODE_RAW_REPLAY=1` to fall back to
    /// the old raw byte replay if a seed rendering issue ever surfaces in the wild.
    public static var useModelSeed: Bool {
        env["JUANCODE_RAW_REPLAY"] != "1"
    }

    /// Hard ceiling on concurrently *live* sessions (juancode-agy). Each spawned
    /// claude/codex tree holds 100-400MB, and nothing else bounds the peak: the
    /// idle reaper (`reapIdleMinutes`) only reclaims *verifiably idle* trees, so a
    /// burst of actively-working agents (Oracle dispatch, fan-out, ⌘N) can still
    /// exhaust RAM and freeze the machine. Past this cap the registry refuses to
    /// spawn. Dormant/exited tiles don't count — only trees holding a pty. Default
    /// 8 sits below the ~11-12 that froze the box yet leaves room for a normal
    /// fan-out. `JUANCODE_MAX_SESSIONS`; a value ≤ 0 disables the cap.
    public static var maxLiveSessions: Int {
        env["JUANCODE_MAX_SESSIONS"].flatMap(Int.init) ?? 8
    }
}
