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

    /// Where rolling diagnostic logs live (the session activity log). Defaults to
    /// `~/.juancode/logs`, beside the default data dir; when `JUANCODE_DATA_DIR`
    /// is overridden the logs follow it (`<dataDir>/logs`) so a relocated install
    /// keeps everything under one root.
    public static var logsDir: String {
        if let override = env["JUANCODE_DATA_DIR"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("logs")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/logs")
    }

    /// Max bytes of terminal output retained (and persisted) per session for
    /// replay on (re)attach (`JUANCODE_SCROLLBACK`, default 256 KiB).
    public static var scrollbackLimit: Int {
        env["JUANCODE_SCROLLBACK"].flatMap(Int.init) ?? 256 * 1024
    }

    /// Max persisted sessions kept per project (worktrees folded into their repo,
    /// see `projectCwd`). Archived sessions don't count toward the cap and are never
    /// pruned. Older unarchived sessions beyond the cap are hard-deleted at startup
    /// and on each new session. Disabled by default (a value ≤ 0 disables the cap)
    /// because the delete is destructive and cost users sessions they wanted to keep;
    /// set `JUANCODE_SESSIONS_PER_PROJECT` to a positive number to re-enable pruning.
    public static var sessionsPerProjectCap: Int {
        env["JUANCODE_SESSIONS_PER_PROJECT"].flatMap(Int.init) ?? 0
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

    /// Explicit `JUANCODE_REAP_IDLE_MINUTES` override, nil when unset. When set it
    /// wins over the Settings → Sessions idle window (the usual `JUANCODE_*`
    /// precedence: env beats persisted config); a value ≤ 0 disables reaping.
    public static var reapIdleMinutesOverride: Int? {
        env["JUANCODE_REAP_IDLE_MINUTES"].flatMap(Int.init)
    }

    /// How long a session must be verifiably idle before the reaper kills its CLI
    /// process tree to free RAM, leaving a dormant, resumable tile.
    /// `JUANCODE_REAP_IDLE_MINUTES`, default 30. Only the boot default — the GUI
    /// re-applies the user's Settings value (or the env override) via
    /// `SessionReaper.setIdleWindow` right after launch.
    public static var reapIdleMinutes: Int {
        reapIdleMinutesOverride ?? 30
    }

    /// The editor an "open editor" session launches, rooted in the source
    /// session's working directory (`JUANCODE_EDITOR`, default `nvim`). May carry
    /// leading args (e.g. `"code -w"`); the launcher splits on whitespace and
    /// resolves the binary against the login-shell PATH.
    public static var editor: String {
        let e = (env["JUANCODE_EDITOR"] ?? "").trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? "nvim" : e
    }

    /// Whether the GitHub webhook chain is configured for this process
    /// (`JUANCODE_GH_WEBHOOK_SECRET` non-empty). The sidecar verifies webhook
    /// HMACs with the same secret and forwards repo+number triggers to the native
    /// `/api/pr-webhook`, making webhooks the fast path for tracked-PR updates.
    public static var ghWebhookConfigured: Bool {
        !(env["JUANCODE_GH_WEBHOOK_SECRET"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Tracked-PR poll cadence, gated on webhook mode: with webhooks delivering
    /// changes in near-real-time, the poll demotes to a slow reconciler that only
    /// catches what the webhook path missed (sidecar down, delivery dropped).
    /// Without webhooks the poll stays the sole update path at the original 60s.
    public static func prPollInterval(webhookConfigured: Bool) -> Duration {
        webhookConfigured ? .seconds(300) : .seconds(60)
    }

    /// The effective tracked-PR poll interval for this process.
    public static var prPollInterval: Duration {
        prPollInterval(webhookConfigured: ghWebhookConfigured)
    }

    /// Seed a freshly-attached local terminal pane from the parsed headless model
    /// (a clean repaint via `SessionTerminalModel.seedBytes()`) instead of replaying
    /// the raw byte ring (juancode-a2h.2) — killing replay-garble and the synthetic
    /// alt-screen resync. On by default; set `JUANCODE_RAW_REPLAY=1` to fall back to
    /// the old raw byte replay if a seed rendering issue ever surfaces in the wild.
    public static var useModelSeed: Bool {
        env["JUANCODE_RAW_REPLAY"] != "1"
    }
}
