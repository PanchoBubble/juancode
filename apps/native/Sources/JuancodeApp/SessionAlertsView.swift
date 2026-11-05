import Foundation
import SwiftUI
import JuancodeCore

/// Uses the same durable subscriptions as the agent tools, including dispatch
/// subscriptions whose source has not emitted its first activity event yet.
private struct SessionAlertSubscription: Decodable, Identifiable {
    let id: String
    let subscriber: String
    let targetType: String
    let targetId: String
    let sourceSessionId: String?
}

struct SessionAlertsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let session: SessionMeta
    @State private var subscriptions: [SessionAlertSubscription] = []
    @State private var loaded = false
    @State private var working = false
    @State private var loadError: String?

    private var incoming: [SessionAlertSubscription] {
        subscriptions.filter {
            $0.sourceSessionId == session.id
                || ($0.targetType == "session" && $0.targetId == session.id)
                || ($0.targetType == "dispatch" && $0.targetId == session.dispatchId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Session Alerts").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(session.title).foregroundStyle(.secondary).lineLimit(2)
            if !loaded {
                Text(loadError ?? "Loading subscriptions…").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sessions receiving updates from this session").font(.subheadline)
                        if incoming.isEmpty { Text("No subscribers").foregroundStyle(.secondary) }
                        ForEach(incoming) { row in
                            HStack {
                                Text(title(row.subscriber))
                                Spacer()
                                Button("Unsubscribe") { change(method: "DELETE", suffix: "/\(row.id)") }
                            }
                        }
                        Menu("Subscribe Session…") {
                            ForEach(model.sessions.filter {
                                $0.kind == .agent && $0.id != session.id && model.isLive($0.id)
                            }, id: \.id) { receiver in
                                Button(title(receiver.id)) {
                                    // Reuse a dispatch target to avoid duplicate routes.
                                    let dispatch = session.dispatchId
                                    change(method: "POST", body: [
                                        "subscriber": receiver.id,
                                        "targetType": dispatch == nil ? "session" : "dispatch",
                                        "targetId": dispatch ?? session.id,
                                    ])
                                }
                                .disabled(incoming.contains { $0.subscriber == receiver.id })
                            }
                        }
                        Divider()
                        Text("Updates received by this session").font(.subheadline)
                        let outgoing = subscriptions.filter { $0.subscriber == session.id }
                        if outgoing.isEmpty { Text("No subscriptions").foregroundStyle(.secondary) }
                        ForEach(outgoing) { row in
                            HStack {
                                Text(title(row.sourceSessionId ?? row.targetId))
                                Spacer()
                                Button("Unsubscribe") { change(method: "DELETE", suffix: "/\(row.id)") }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Refresh") { refresh() }
                if working { ProgressView().controlSize(.small) }
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .disabled(working)
        .task { refresh() }
    }

    private func title(_ id: String) -> String {
        let name = model.sessions.first { $0.id == id }?.title ?? "Session"
        return "\(name) (\(id.prefix(8)))"
    }

    private func request(method: String = "GET", suffix: String = "",
                         body: [String: String]? = nil) async throws -> Data {
        let url = URL(string: "\(SessionHandoff.sidecarBase)/api/session-subscriptions\(suffix)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
        else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "SessionAlerts", code: 1, userInfo: [
                NSLocalizedDescriptionKey: error?["error"] as? String ?? "Subscription request failed",
            ])
        }
        return data
    }

    private func refresh() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                subscriptions = try JSONDecoder().decode([SessionAlertSubscription].self,
                                                         from: await request())
                loaded = true
                loadError = nil
            } catch {
                loaded = false
                loadError = "Subscriptions unavailable — refresh to retry"
                model.errorMessage = "Couldn't load session alerts: \(error.localizedDescription)"
            }
        }
    }

    private func change(method: String, suffix: String = "", body: [String: String]? = nil) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await request(method: method, suffix: suffix, body: body)
                subscriptions = try JSONDecoder().decode([SessionAlertSubscription].self,
                                                         from: await request())
                loaded = true
            } catch {
                loaded = false
                loadError = "Couldn't update subscriptions — refresh to retry"
                model.errorMessage = "Couldn't update session alerts: \(error.localizedDescription)"
            }
        }
    }
}
