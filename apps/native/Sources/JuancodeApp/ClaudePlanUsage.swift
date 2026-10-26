// The sidebar footer's Claude plan meter: how much of the weekly limit (and the
// rolling 5-hour window) this account has used — the numbers `/usage` shows inside
// Claude Code.
//
// They come from the same place `/usage` gets them: `GET /api/oauth/usage` with the
// OAuth token Claude Code keeps in the login keychain. The token is read through
// `/usr/bin/security` rather than the Security framework because the item's ACL
// already trusts that binary (it is how the CLI wrote it), so the app never raises a
// keychain prompt of its own. The endpoint is undocumented; anything unexpected —
// no token, an expired one, a changed shape — just hides the row.

import SwiftUI

struct ClaudePlanUsage: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        /// Percent of the window's limit used, 0–100.
        let utilization: Double
        let resetsAt: Date?
    }

    let fiveHour: Window?
    let sevenDay: Window?

    /// Fetch the account's plan usage, or nil when it can't be had.
    static func fetch() async -> ClaudePlanUsage? {
        guard let token = await accessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let usage = ClaudePlanUsage(fiveHour: window(json["five_hour"]),
                                    sevenDay: window(json["seven_day"]))
        return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
    }

    private static func window(_ raw: Any?) -> Window? {
        guard let dict = raw as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetsAt = (dict["resets_at"] as? String).flatMap { formatter.date(from: $0) }
        return Window(utilization: utilization, resetsAt: resetsAt)
    }

    /// Claude Code's OAuth access token, off the main thread.
    private static func accessToken() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any]
            else { return nil }
            return oauth["accessToken"] as? String
        }.value
    }
}

/// One footer row: a bar for the week, the week's percent, and the 5-hour percent.
/// Polls every five minutes while the sidebar is on screen.
struct ClaudePlanUsageFooter: View {
    @State private var usage: ClaudePlanUsage?

    var body: some View {
        Group {
            if let usage, let week = usage.sevenDay {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 6) {
                        Text("Week").font(.system(size: 11)).foregroundStyle(.secondary)
                        ProgressView(value: min(max(week.utilization, 0), 100), total: 100)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(Self.tint(week.utilization) ?? .accentColor)
                        Text(Self.percent(week.utilization))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Self.tint(week.utilization) ?? .secondary)
                        if let fiveHour = usage.fiveHour {
                            Text("5h \(Self.percent(fiveHour.utilization))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Self.tint(fiveHour.utilization) ?? .secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .help(Self.helpText(usage))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let fresh = await ClaudePlanUsage.fetch() { usage = fresh }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Amber from 80%, red from 95%; nil (secondary) below that.
    private static func tint(_ value: Double) -> Color? {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return nil
    }

    private static func helpText(_ usage: ClaudePlanUsage) -> String {
        var lines = ["Claude plan usage (what /usage shows)"]
        if let week = usage.sevenDay {
            lines.append("Week: \(percent(week.utilization)) used" + resets(week.resetsAt))
        }
        if let fiveHour = usage.fiveHour {
            lines.append("5-hour window: \(percent(fiveHour.utilization)) used" + resets(fiveHour.resetsAt))
        }
        return lines.joined(separator: "\n")
    }

    private static func resets(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return " · resets \(formatter.string(from: date))"
    }
}
