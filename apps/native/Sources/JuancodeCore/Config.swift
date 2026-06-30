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
    /// want LAN reachability (e.g. `0.0.0.0`); always pair a non-loopback bind with
    /// `JUANCODE_TOKEN` since the server then accepts connections from the network.
    public static var bindHost: String {
        let h = (env["JUANCODE_HOST"] ?? "").trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? "127.0.0.1" : h
    }

    /// The remote-access auth token, or "" when auth is disabled.
    ///
    /// Resolution order:
    ///   1. `JUANCODE_TOKEN` env var (explicit opt-in; matches the Node server) —
    ///      an empty/whitespace value disables auth.
    ///   2. otherwise a token persisted in the data dir (`remoteToken`), if present.
    ///
    /// Auth stays OFF until a token exists by one of these means, so plain local
    /// use is unaffected. Call `ensureRemoteToken()` to self-provision one (e.g.
    /// when the user turns on remote access) and `remoteTokenPath` to surface it.
    public static var remoteToken: String {
        if let env = env["JUANCODE_TOKEN"] {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return persistedRemoteToken() ?? ""
    }

    /// File the self-provisioned token is persisted to (inside `dataDir`). The
    /// in-app UI can read this to display/hand off the token to the phone/tunnel.
    public static var remoteTokenPath: String {
        (dataDir as NSString).appendingPathComponent("remote-token")
    }

    private static func persistedRemoteToken() -> String? {
        guard let raw = try? String(contentsOfFile: remoteTokenPath, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Return the existing token, or generate + persist a fresh one and return it.
    /// A `JUANCODE_TOKEN` env override always wins and is returned untouched (never
    /// persisted). Generates 32 bytes of crypto-random entropy as URL-safe base64.
    @discardableResult
    public static func ensureRemoteToken() -> String {
        if let env = env["JUANCODE_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        if let existing = persistedRemoteToken() { return existing }
        let token = generateToken()
        let dir = (remoteTokenPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Persist owner-only (0600); best-effort if the FS doesn't honor it.
        try? token.write(toFile: remoteTokenPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: remoteTokenPath)
        return token
    }

    /// 32 bytes of secure random as URL-safe base64 (no padding) — safe in a
    /// `?token=` query param and an `Authorization: Bearer` header.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        let b64 = Data(bytes).base64EncodedString()
        return b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
}
