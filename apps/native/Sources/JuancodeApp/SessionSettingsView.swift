// Settings → Sessions pane: auto-close idle sessions. Kill (but keep, resumable)
// any running session with no output for the chosen duration, so unused agents stop
// holding a live pty. The duration is editable; the toggle off (0 min) disables it
// entirely. Backed by `AppModel.autoCloseIdleMinutes`; the work runs on the health
// loop (see `autoCloseIdleSessions`). Surfaced via the standard ⌘, window.

import SwiftUI

struct SessionSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Draft minutes the stepper edits, kept separate from the model so toggling the
    /// feature off (which sets the model to 0) doesn't lose the chosen duration.
    @State private var minutes = 60

    private var enabled: Bool { model.autoCloseIdleMinutes > 0 }

    /// Draft budget the field edits, kept separate so toggling off (model → 0)
    /// doesn't lose the chosen amount (juancode-qoc).
    @State private var budget = 20.0
    private var budgetEnabled: Bool { model.costBudgetUsd > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically close idle sessions", isOn: Binding(
                    get: { enabled },
                    set: { model.autoCloseIdleMinutes = $0 ? minutes : 0 }))

                HStack(spacing: 8) {
                    Text("Close after")
                    Stepper(value: $minutes, in: 5...1440, step: 5) {
                        Text("\(minutes) min").monospacedDigit()
                    }
                    .fixedSize()
                    .onChange(of: minutes) { _, m in
                        if enabled { model.autoCloseIdleMinutes = m }
                    }
                    Text("of inactivity")
                }
                .disabled(!enabled)
                .foregroundStyle(enabled ? .primary : .secondary)

                Divider().padding(.vertical, 4)

                // Estimated-cost budget (juancode-qoc): colours the sidebar total
                // amber past the warn threshold and red at/over budget.
                Toggle("Warn on estimated cost budget", isOn: Binding(
                    get: { budgetEnabled },
                    set: { model.costBudgetUsd = $0 ? budget : 0 }))

                HStack(spacing: 8) {
                    Text("Budget")
                    TextField("USD", value: $budget, format: .currency(code: "USD"))
                        .frame(width: 90)
                        .onChange(of: budget) { _, b in if budgetEnabled { model.costBudgetUsd = max(0, b) } }
                    Text("· warn at")
                    Stepper(value: Binding(
                        get: { model.costBudgetWarnPercent },
                        set: { model.costBudgetWarnPercent = $0 }), in: 10...100, step: 5) {
                        Text("\(model.costBudgetWarnPercent)%").monospacedDigit()
                    }
                    .fixedSize()
                }
                .disabled(!budgetEnabled)
                .foregroundStyle(budgetEnabled ? .primary : .secondary)

                Divider().padding(.vertical, 4)

                // Notification routing (juancode-xac): POST a Slack-compatible JSON
                // to this URL on turn-end / needs-input. Empty = off; nothing sends
                // without a URL. Gated by the turn-end notifications toggle above.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notification webhook")
                    TextField("https://hooks.slack.com/services/…", text: Binding(
                        get: { model.notifyWebhookUrl },
                        set: { model.notifyWebhookUrl = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("POSTs a Slack-compatible JSON on turn-end / needs-input so background work reaches you off-device. Any incoming-webhook URL works.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Spacer()

            Divider()
            Text("Stops the agent and frees its pty so an unused session isn't held "
                + "open. The session stays in the list and can be resumed later. "
                + "“No output” for the chosen time counts as inactive — a session "
                + "that's actively working is never closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if enabled { minutes = model.autoCloseIdleMinutes }
            if budgetEnabled { budget = model.costBudgetUsd }
        }
    }
}
