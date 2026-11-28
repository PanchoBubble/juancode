import JuancodeWire
import SwiftUI

/// Start an agent session on the Mac: project, provider, model, worktree. Dismisses
/// and opens the session once the core answers `created`.
struct NewSessionSheet: View {
    let core: RemoteCore
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var provider = ProviderId.claude
    @State private var model = ""
    @State private var worktree = true
    @State private var starting = false

    // shortcut: projects are the cwds already seen in sessions; a new repo needs a first session from the Mac.
    private var projects: [String] { ProjectGroup.group(core.sessions).map(\.path) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Project", selection: $cwd) {
                    ForEach(projects, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                }
                Picker("Provider", selection: $provider) {
                    Text("Claude").tag(ProviderId.claude)
                    Text("Codex").tag(ProviderId.codex)
                }
                .pickerStyle(.segmented)
                TextField("Model (default)", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Own worktree", isOn: $worktree)
                if let e = core.lastError, starting { Text(e).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        starting = true
                        core.onCreated = { id in open(id); dismiss() }
                        core.create(provider: provider, cwd: cwd, model: model.trimmingCharacters(in: .whitespaces), worktree: worktree)
                    }
                    .disabled(cwd.isEmpty || starting && core.lastError == nil)
                }
            }
            .onAppear { if cwd.isEmpty { cwd = projects.first ?? "" } }
        }
    }
}
