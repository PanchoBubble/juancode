import SwiftUI
import JuancodeServices

/// "Ask AI to change my settings" (juancode-bdlq): a small prompt where the user
/// says, in plain language, what to change. It runs a one-shot headless `claude -p`
/// turn (see `SettingsAI.swift`) that has the full set of allowed settings + their
/// current values as context, then shows a preview diff to confirm before anything
/// is written. Nothing changes without the explicit Apply.
struct SettingsAIView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var running = false
    @State private var result: SettingsAIResult?
    @FocusState private var promptFocused: Bool

    /// One previewed change: a human label and the before → after values.
    private struct Change: Identifiable {
        let id = UUID()
        let label: String
        let from: String
        let to: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                Text("Ask AI to change settings").font(.title3).bold()
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Describe what you want changed — e.g. \"sleep idle sessions after 20 minutes\", \"warn me at $50\", \"switch to light mode\".")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("What should change?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($promptFocused)
                        .onSubmit(run)
                        .disabled(running)
                    Button(action: run) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.borderless)
                    .disabled(running || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
                    .help("Ask AI")
                }

                if let result { resultBody(result) }
            }
            .padding(16)

            Spacer(minLength: 0)

            Divider()
            Text("Runs your signed-in `claude` once, non-interactively. Reads the current settings and proposes changes; nothing is written until you Apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 520, height: 460)
        .onAppear { promptFocused = true }
    }

    @ViewBuilder
    private func resultBody(_ r: SettingsAIResult) -> some View {
        if let error = r.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let changes = changes(for: r.patch)
            if !r.explanation.isEmpty {
                Text(r.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if changes.isEmpty {
                Label("No settings to change.", systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(changes) { c in
                        HStack(spacing: 6) {
                            Text(c.label).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 8)
                            Text(c.from).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(c.to).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.appHairline(0.06)))
                HStack {
                    Spacer()
                    Button("Discard") { result = nil }.clickCursor()
                    Button("Apply") { apply(r.patch); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .clickCursor()
                }
            }
        }
    }

    private func run() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        running = true
        result = nil
        let snapshot = SettingsSnapshot(
            autoCloseIdleMinutes: model.autoCloseIdleMinutes,
            costBudgetUsd: model.costBudgetUsd,
            costBudgetWarnPercent: model.costBudgetWarnPercent,
            notifyOnTurnEnd: model.notifyOnTurnEnd,
            keepAwake: model.keepAwake,
            theme: model.themePreference.rawValue,
            hasWebhook: !model.notifyWebhookUrl.isEmpty)
        Task {
            let r = await runSettingsAI(prompt: text, current: snapshot)
            await MainActor.run {
                result = r
                running = false
            }
        }
    }

    /// Build the preview rows: only fields the patch actually changes vs the model.
    private func changes(for patch: SettingsPatch) -> [Change] {
        var out: [Change] = []
        if let v = patch.autoCloseIdleMinutes {
            let clamped = clampIdle(v)
            if clamped != model.autoCloseIdleMinutes {
                out.append(Change(label: "Sleep idle after", from: idleLabel(model.autoCloseIdleMinutes), to: idleLabel(clamped)))
            }
        }
        if let v = patch.costBudgetUsd {
            let clamped = max(0, v)
            if clamped != model.costBudgetUsd {
                out.append(Change(label: "Cost budget", from: budgetLabel(model.costBudgetUsd), to: budgetLabel(clamped)))
            }
        }
        if let v = patch.costBudgetWarnPercent {
            let clamped = min(100, max(10, v))
            if clamped != model.costBudgetWarnPercent {
                out.append(Change(label: "Warn at", from: "\(model.costBudgetWarnPercent)%", to: "\(clamped)%"))
            }
        }
        if let v = patch.notifyOnTurnEnd, v != model.notifyOnTurnEnd {
            out.append(Change(label: "Turn-end notifications", from: onOff(model.notifyOnTurnEnd), to: onOff(v)))
        }
        if let v = patch.keepAwake, v != model.keepAwake {
            out.append(Change(label: "Keep awake", from: onOff(model.keepAwake), to: onOff(v)))
        }
        if let t = patch.theme, t != model.themePreference.rawValue,
           let pref = ThemePreference(rawValue: t) {
            out.append(Change(label: "Appearance", from: model.themePreference.label, to: pref.label))
        }
        if patch.clearWebhook == true, !model.notifyWebhookUrl.isEmpty {
            out.append(Change(label: "Notification webhook", from: "set", to: "off"))
        }
        return out
    }

    private func apply(_ patch: SettingsPatch) {
        if let v = patch.autoCloseIdleMinutes { model.autoCloseIdleMinutes = clampIdle(v) }
        if let v = patch.costBudgetUsd { model.costBudgetUsd = max(0, v) }
        if let v = patch.costBudgetWarnPercent { model.costBudgetWarnPercent = min(100, max(10, v)) }
        if let v = patch.notifyOnTurnEnd { model.notifyOnTurnEnd = v }
        if let v = patch.keepAwake { model.keepAwake = v }
        if let t = patch.theme, let pref = ThemePreference(rawValue: t) { model.themePreference = pref }
        if patch.clearWebhook == true { model.notifyWebhookUrl = "" }
    }

    // 0 = disabled; otherwise 5...1440.
    private func clampIdle(_ v: Int) -> Int { v <= 0 ? 0 : min(1440, max(5, v)) }
    private func idleLabel(_ m: Int) -> String { m <= 0 ? "off" : "\(m) min" }
    private func budgetLabel(_ v: Double) -> String { v <= 0 ? "off" : String(format: "$%.0f", v) }
    private func onOff(_ b: Bool) -> String { b ? "on" : "off" }
}
