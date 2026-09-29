import Foundation

/// The daemon's data dir, where its store and its small JSON configs live. Mirrors
/// `juancoded_core::notify::daemon_data_dir`.
public enum DaemonDataDir {
    public static var path: String {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        return value("JUANCODED_DATA_DIR") ?? value("JUANCODE_DATA_DIR")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/rust-core")
    }
}

/// How many deleted sessions' worktrees the daemon keeps per repo for reuse
/// (`juancoded-core/src/worktree/pool.rs`). Written here, read by the daemon on every
/// create and delete, so a change needs no restart.
///
/// `worktree-pool.json` beside the daemon's store: `{"maxIdlePerRepo": 20}`. `0`
/// turns reuse off.
public enum WorktreePoolConfig {
    public static let defaultMaxIdle = 20

    /// Mirrors `juancoded_core::worktree::pool::config_path`.
    public static var path: String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["JUANCODE_WORKTREE_POOL_CONFIG"], !explicit.isEmpty { return explicit }
        return (DaemonDataDir.path as NSString).appendingPathComponent("worktree-pool.json")
    }

    public static func maxIdle(at path: String = WorktreePoolConfig.path) -> Int {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["maxIdlePerRepo"] as? Int, n >= 0
        else { return defaultMaxIdle }
        return n
    }

    /// Other keys in the file are preserved. Returns whether the file was written.
    @discardableResult
    public static func setMaxIdle(_ n: Int, at path: String = WorktreePoolConfig.path) -> Bool {
        var obj: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj["maxIdlePerRepo"] = max(0, n)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
