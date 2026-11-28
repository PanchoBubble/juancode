import Foundation

/// The Mac's half of phone alerts (juancode-3aq8.7). The sidecar decides and sends
/// the ntfy push (`phone-alerts.ts`); this side only reports the two facts it can
/// see: whether the Mac is away (`PresenceReporter` in the app) and which sessions
/// the phone started or typed into (the relay, below).
public enum PhoneAlerts {
    /// `ORACLE_MCP_PORT` when this process has it, else the sidecar's own default.
    public static var sidecarBase: String {
        "http://127.0.0.1:\(ProcessInfo.processInfo.environment["ORACLE_MCP_PORT"] ?? "4281")"
    }

    /// Fire and forget: a sidecar that is down must never slow the relay or the app.
    public static func post(_ path: String, _ body: [String: Any]) {
        guard let url = URL(string: sidecarBase + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    private static let reported = NSLock()
    nonisolated(unsafe) private static var reportedIds = Set<String>()

    /// Once per session per process: typing sends a frame per key.
    static func driven(_ sessionId: String) {
        reported.lock()
        let isNew = reportedIds.insert(sessionId).inserted
        reported.unlock()
        if isNew { post("/api/phone-alerts/driven", ["sessionId": sessionId]) }
    }
}

/// One remote relay connection's view of "the phone is driving": a `create` frame is
/// answered later by `created` with the new id; `input`/`key` name their session.
final class PhoneDrive: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCreates = 0

    func fromClient(_ text: String) {
        guard let obj = Self.object(text), let type = obj["type"] as? String else { return }
        switch type {
        case "create":
            lock.lock(); pendingCreates += 1; lock.unlock()
        case "input", "key":
            if let id = obj["sessionId"] as? String { PhoneAlerts.driven(id) }
        default: break
        }
    }

    func fromCore(_ text: String) {
        lock.lock(); let waiting = pendingCreates > 0; lock.unlock()
        // `output` frames dominate; only parse when a create is actually outstanding.
        guard waiting, text.contains("\"created\""), let obj = Self.object(text),
              obj["type"] as? String == "created",
              let id = (obj["session"] as? [String: Any])?["id"] as? String else { return }
        lock.lock(); pendingCreates -= 1; lock.unlock()
        PhoneAlerts.driven(id)
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
