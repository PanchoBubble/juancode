import SwiftUI
import JuancodeCore

/// "Address comments": pick the PRs, check the prompt, and start one agent per PR.
///
/// The prompt and the repo's review-trigger comment are editable here rather than in a
/// settings pane — the thing being confirmed is exactly what each agent will be told —
/// and whatever is left in the fields when you press Start is what is remembered.
struct PrAddressCommentsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: String
    let cwd: String
    /// The repo's PRs that are the viewer's own and have unresolved threads.
    let candidates: [PullRequest]

    @State private var chosen: Set<Int> = []
    @State private var template = ""
    @State private var reviewCommand = ""
    @State private var provider: ProviderId = .claude
    @State private var selectedModel: String?
    @State private var showPrompt = false

    private var chosenInOrder: [PullRequest] { candidates.filter { chosen.contains($0.number) } }
    private var plan: PrAddressComments.Plan {
        model.addressCommentsPlan(chosenInOrder, repo: repo, cwd: cwd)
    }
    private func skip(_ number: Int) -> PrAddressComments.Skip? {
        model.addressCommentsPlan(candidates, repo: repo, cwd: cwd)
            .skipped.first { $0.number == number && $0.why != .overCap }?.why
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Address comments in \(repo)").font(.title2).bold()
                Text("One agent per PR, each on its own worktree. It checks every unresolved thread against the code, fixes or declines it, replies, resolves it, and asks for a new review.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates, id: \.number) { pr in row(pr) }
                }
            }
            .frame(maxHeight: 180)

            summary

            VStack(alignment: .leading, spacing: 4) {
                Text("Re-review comment").font(.system(size: 13, weight: .semibold))
                TextField("e.g. /review — leave empty if this repo has no re-review trigger",
                          text: $reviewCommand)
                    .textFieldStyle(.roundedBorder)
                Text("Posted on each PR once its threads are answered. Remembered for \(repo).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showPrompt) {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $template)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 190)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    HStack {
                        Text("Filled per PR: " + PrAddressComments.placeholders.joined(separator: " "))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Reset") { template = PrAddressComments.defaultTemplate }
                            .buttonStyle(.borderless).font(.system(size: 11))
                            .disabled(template == PrAddressComments.defaultTemplate)
                    }
                }
            } label: {
                Text("Prompt").font(.system(size: 13, weight: .semibold))
            }

            HStack {
                Picker("Agent", selection: $provider) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        Text(Providers.spec(for: p).label).tag(p)
                    }
                }
                if provider == .claude || provider == .codex {
                    AgentModelPicker(provider: provider, selection: $selectedModel).id(provider)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).clickCursor()
                Button(plan.start.isEmpty ? "Start" : "Start \(plan.start.count)") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.start.isEmpty
                              || template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            template = model.addressCommentsTemplate
            reviewCommand = model.addressCommentsReviewCommand(forRepo: repo)
            // Pre-pick what one batch would start, so Cmd-Return is the whole interaction.
            let startable = model.addressCommentsPlan(candidates, repo: repo, cwd: cwd).start
            chosen = Set(startable)
        }
        .onChange(of: provider) { _, _ in selectedModel = nil }
    }

    private func row(_ pr: PullRequest) -> some View {
        let blocked = skip(pr.number)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { chosen.contains(pr.number) && blocked == nil },
                set: { on in if on { chosen.insert(pr.number) } else { chosen.remove(pr.number) } }
            )) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(blocked != nil)
            Text(verbatim: "#\(pr.number)")
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Text(pr.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let blocked {
                Text(blocked.label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Image(systemName: "bubble.left.fill").font(.system(size: 9)).foregroundStyle(.orange)
            Text(verbatim: "\(pr.unresolvedComments)")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var summary: some View {
        let over = plan.skipped.filter { $0.why == .overCap }.map { "#\($0.number)" }
        if !over.isEmpty {
            Text("Only \(PrAddressComments.batchCap) start at a time. \(over.joined(separator: ", ")) will be left for the next batch.")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private func start() {
        model.addressComments(chosenInOrder, repo: repo, cwd: cwd, template: template,
                              reviewCommand: reviewCommand, provider: provider, model: selectedModel)
        dismiss()
    }
}
