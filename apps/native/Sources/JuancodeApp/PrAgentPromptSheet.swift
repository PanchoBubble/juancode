import SwiftUI
import JuancodeCore

struct AgentPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let url: String
    let promptHelp: String
    var modelSelection: Binding<String?>? = nil
    let onStart: @MainActor (ProviderId, String) async -> Bool

    @State private var provider: ProviderId = .claude
    @State private var prompt = ""
    @State private var creating = false
    @FocusState private var promptFocused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2).bold()
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.system(size: 13, weight: .semibold))
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(height: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    .focused($promptFocused)
                    .disabled(creating)
                Text(promptHelp)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Picker("Agent", selection: $provider) {
                ForEach(ProviderId.allCases, id: \.self) { provider in
                    Text(Providers.spec(for: provider).label).tag(provider)
                }
            }
            .disabled(creating)

            if let modelSelection, provider == .claude || provider == .codex {
                AgentModelPicker(provider: provider, selection: modelSelection)
                    .id(provider)
                    .disabled(creating)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creating)
                    .clickCursor()
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || trimmedPrompt.isEmpty)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { promptFocused = true }
        .onChange(of: provider) { _, _ in modelSelection?.wrappedValue = nil }
    }

    private func start() {
        let prompt = trimmedPrompt
        guard !prompt.isEmpty, !creating else { return }
        creating = true
        Task {
            let started = await onStart(provider, prompt)
            creating = false
            if started { dismiss() }
        }
    }
}

struct PrAgentPromptSheet: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    @State private var selectedModel: String?

    var body: some View {
        AgentPromptSheet(
            title: "Work on PR #\(pr.number)", subtitle: pr.title, url: pr.url,
            promptHelp: "The PR link and your prompt are sent when the agent starts.",
            modelSelection: $selectedModel
        ) { provider, prompt in
            let session = await model.create(
                provider: provider, cwd: cwd, skipPermissions: true,
                isolateWorktree: false, initialInput: "\(pr.url)\n\n\(prompt)",
                model: selectedModel)
            return session != nil
        }
    }
}

/// The PR row's one-click prompt (paperplane): the text you would otherwise retype in
/// the Agent sheet every time. Edited in Settings → Sessions.
enum PrQuickPrompt {
    static let key = "github.queue.quickPrompt"
    static let defaultText = "Let's address these comments; ask if you have any concerns. "
        + "After that, resolve the threads, update with the latest main and trigger a new review."

    static var text: String {
        let saved = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultText : saved
    }

    /// A tracked PR already has an agent on its branch, so the prompt is queued there
    /// (delivered at its next idle edge); otherwise it starts a fresh Claude session
    /// exactly as the Agent sheet's Start does.
    @MainActor static func send(_ pr: PullRequest, cwd: String, model: AppModel) {
        let prompt = text
        Task {
            if let t = model.trackedPr(cwd: cwd, number: pr.number), !model.isTrackPending(t) {
                await model.queuePrompt(sessionId: t.sessionId, text: prompt)
            } else {
                _ = await model.create(provider: .claude, cwd: cwd, skipPermissions: true,
                                       isolateWorktree: false, initialInput: "\(pr.url)\n\n\(prompt)")
            }
        }
    }
}
