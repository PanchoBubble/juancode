import Foundation

/// The sidecar's phone-alert state (`phone-alerts.ts`): the ntfy topic to subscribe to
/// in the ntfy app, and the sessions whose alerts are muted. Alerts are on by default.
struct AlertsState: Decodable, Equatable {
    var topic: String
    var muted: [String]
}

enum AlertsClient {
    static func fetch(_ pairing: Pairing) async throws -> AlertsState {
        try await send(pairing, "GET", "api/phone-alerts")
    }

    static func setEnabled(_ pairing: Pairing, sessionId: String, enabled: Bool) async throws -> AlertsState {
        try await send(pairing, "PUT", "api/phone-alerts/sessions/\(sessionId)", body: ["enabled": enabled])
    }

    private static func send(_ pairing: Pairing, _ method: String, _ path: String,
                             body: [String: Any]? = nil) async throws -> AlertsState {
        guard let base = pairing.oracle else { throw URLError(.badURL) }
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(AlertsState.self, from: data)
    }
}
