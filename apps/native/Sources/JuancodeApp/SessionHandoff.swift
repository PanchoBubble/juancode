import Foundation
import JuancodeCore

/// Handing a long session off to a fresh one (juancode-u5q): the row action's half.
///
/// The orchestration — queue the note request, wait for the reply, spawn the
/// successor with the note as its first prompt, record the chain handoff, sleep the
/// old session — lives once, in the Oracle sidecar (`session-handoff.ts`), because the
/// `oracle_session_handoff` MCP tool needs exactly the same steps. This side asks for
/// it over the sidecar's HTTP API and reports the outcome, so the two entry points
/// cannot drift into two meanings of "hand off".
///
/// Lives in its own file for the reason `SessionSleepActions.swift` does: a
/// self-contained action that would otherwise grow the model further.

/// UserDefaults key of the handoff line in tokens (0 = off). Views read it through
/// `@AppStorage` so the badge re-tints the moment the setting moves.
let contextHandoffTokensKey = "juancode.contextHandoffTokens"

enum SessionHandoff {
    /// The sidecar's base URL: `ORACLE_MCP_PORT` when this process has it, else the
    /// sidecar's own default.
    static var sidecarBase: String {
        let port = ProcessInfo.processInfo.environment["ORACLE_MCP_PORT"] ?? "4281"
        return "http://127.0.0.1:\(port)"
    }

    /// Longer than the sidecar's own 15-minute wait for the note, so its answer (a
    /// refusal naming the timeout) arrives before this side gives up on the request.
    static let requestTimeout: TimeInterval = 16 * 60

    /// The tooltip line for a session past the handoff line, or nil when it isn't.
    static func hint(_ usage: SessionUsage?, handoffTokens: Int) -> String? {
        guard let usage, usage.contextPressure(handoffTokens: handoffTokens) == .handoff
        else { return nil }
        return "re-reading \(SessionUsageFormat.tokens(handoffTokens))+ every turn — "
            + "consider handing off (row menu › Hand Off to Fresh Session)"
    }
}

extension AppModel {
    /// Hand `id` off to a fresh session. Never automatic: only the row action calls it.
    /// On success the successor is selected; a refusal is shown as the sidecar worded
    /// it, and in that case nothing was spawned and the session was left as it was.
    func handOffSession(_ id: String) {
        guard !handoffsInFlight.contains(id),
              let url = URL(string: "\(SessionHandoff.sidecarBase)/api/sessions/"
                  + "\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/handoff")
        else { return }
        handoffsInFlight.insert(id)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = SessionHandoff.requestTimeout
        Task { @MainActor in
            defer { handoffsInFlight.remove(id) }
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                errorMessage = "Couldn't hand off: the Oracle sidecar at "
                    + "\(SessionHandoff.sidecarBase) didn't answer (\(error.localizedDescription)). "
                    + "It runs the handoff; start it with `pnpm dev:oracle`."
                return
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if body?["ok"] as? Bool == true, let successor = body?["successorId"] as? String {
                if let warnings = body?["warnings"] as? [String], !warnings.isEmpty {
                    errorMessage = "Handed off, but " + warnings.joined(separator: "; ") + "."
                }
                if selection == id { selection = successor }
                return
            }
            errorMessage = "Couldn't hand off: "
                + ((body?["error"] as? String) ?? String(decoding: data, as: UTF8.self))
        }
    }
}
