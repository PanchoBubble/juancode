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
