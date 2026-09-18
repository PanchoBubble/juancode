import Foundation

/// Where the notification webhook URL is kept now that the DAEMON fires it
/// (juancode-52e8.14.7).
///
/// The POST used to live in `AppModel`, which meant the one notification whose job is
/// to reach you away from the Mac only fired while the Mac's UI was open. It is now
/// `juancoded`'s (`juancoded-core/src/notify.rs`), and a daemon that had to ask this
/// app for a setting would still be coupled to the process it has to outlive — so the
/// URL lives in the daemon's own config file and this app only writes it there.
///
/// The file is `notify.json` beside the daemon's store, shaped
/// `{"webhookUrl": "https://…"}`. The daemon re-reads it on every notifying turn
/// boundary, so a URL typed in Settings takes effect without restarting it — which
/// matters, because restarting it ends every live session.
public enum NotifyConfig {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static func envValue(_ key: String) -> String? {
        guard let v = env[key], !v.isEmpty else { return nil }
        return v
    }

    /// Mirrors `juancoded_core::notify::config_path`: `JUANCODE_NOTIFY_CONFIG`
    /// outright, else `notify.json` in the daemon's data dir — `JUANCODED_DATA_DIR`
    /// before `JUANCODE_DATA_DIR` (the daemon's own knob wins), defaulting to
    /// `~/.juancode/rust-core`, which is the daemon's store and NOT the Swift core's
    /// `~/.juancode/data`.
    public static var path: String {
        if let explicit = envValue("JUANCODE_NOTIFY_CONFIG") { return explicit }
        let dir = envValue("JUANCODED_DATA_DIR") ?? envValue("JUANCODE_DATA_DIR")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/rust-core")
        return (dir as NSString).appendingPathComponent("notify.json")
    }

    /// The URL the daemon would POST to right now, or `nil` when none is configured.
    /// A missing or malformed file is "no webhook", never an error — the whole path is
    /// best-effort on both sides.
    public static func webhookURL(at path: String = NotifyConfig.path) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["webhookUrl"] as? String
        else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Hand the daemon a new URL (empty clears it). Returns whether the file was
    /// written; a failure is reported rather than thrown, because a webhook that could
    /// not be saved must not take a Settings pane down with it.
    ///
    /// Other keys in the file are preserved, so a knob added to the daemon's config
    /// later is not silently erased by someone typing in this field.
    @discardableResult
    public static func setWebhookURL(_ url: String, at path: String = NotifyConfig.path) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        var obj: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        if trimmed.isEmpty {
            obj.removeValue(forKey: "webhookUrl")
        } else {
            obj["webhookUrl"] = trimmed
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
