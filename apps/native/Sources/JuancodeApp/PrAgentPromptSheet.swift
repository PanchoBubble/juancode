import SwiftUI
import JuancodeCore

struct PrAgentPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pr: PullRequest
    let cwd: String

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
                Text("Work on PR #\(pr.number)")
                    .font(.title2).bold()
                Text(pr.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pr.url)
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
                Text("The PR link and your prompt are sent when the agent starts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Picker("Agent", selection: $provider) {
                ForEach(ProviderId.allCases, id: \.self) { provider in
                    Text(Providers.spec(for: provider).label).tag(provider)
                }
            }
            .disabled(creating)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creating)
                    .clickCursor()
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || trimmedPrompt.isEmpty)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { promptFocused = true }
    }

    private func start() {
        let prompt = trimmedPrompt
        guard !prompt.isEmpty, !creating else { return }
        creating = true
        Task {
            let session = await model.create(
                provider: provider, cwd: cwd, skipPermissions: true,
                isolateWorktree: false, initialInput: "\(pr.url)\n\n\(prompt)")
            creating = false
            if session != nil { dismiss() }
        }
    }
}
