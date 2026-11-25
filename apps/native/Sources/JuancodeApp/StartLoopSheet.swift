import SwiftUI
import JuancodeCore
import JuancodeDesktop

/// Start a loop (juancode-8oa5.13): one orchestrator session running the run-loop
/// skill on a bd epic or a free-text goal.
///
/// It goes through the sidecar's `/api/dispatch`, the path every other dispatch
/// takes: that appends the orchestrator role template, and the daemon gives a
/// dispatch with no source session its own top-level chain in the same step as the
/// create, so there is no separate "make the chain" call to half-fail. Retries are
/// safe twice over: the sheet keeps one idempotency key for its whole life, and an
/// epic is sent as the dispatch `ticket`, so a second loop on an epic that already
/// has a live orchestrator is refused and that session is selected instead.

struct StartLoopSeed: Identifiable {
    /// Also the dispatch idempotency key: every Start from one sheet is one dispatch.
    let id = UUID().uuidString.lowercased()
    var epic: String?
    var epicTitle: String?
    var cwd: String
}

extension AppModel {
    /// Open the Start Loop sheet. `epic` pre-fills it from a beads row; otherwise it
    /// opens on the selected session's project.
    func startLoop(epic: BeadsIssue? = nil, cwd: String? = nil) {
        let project = cwd ?? newSessionTarget().map { projectCwd(for: $0.cwd) } ?? Config.defaultCwd
        startLoopSeed = StartLoopSeed(epic: epic?.id, epicTitle: epic?.title, cwd: project)
    }
}

struct StartLoopSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let seed: StartLoopSeed

    @State private var goal = ""
    @State private var cwd = ""
    @State private var templateId = ""
    @State private var provider: ProviderId = .claude
    @State private var selectedModel: String?
    @State private var roundCap = 3
    @State private var budget = ""
    @State private var starting = false
    @State private var error: String?

    private var trimmedGoal: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool {
        !starting && !cwd.trimmingCharacters(in: .whitespaces).isEmpty
            && (seed.epic != nil || !trimmedGoal.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start Loop").font(.title2).bold()
                if let epic = seed.epic {
                    Text("\(epic)  \(seed.epicTitle ?? "")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("An orchestrator plans, dispatches implementers and testers, and asks you in the chain when it needs you.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField(seed.epic == nil ? "Goal" : "Notes for the orchestrator (optional)",
                          text: $goal, axis: .vertical)
                    .lineLimit(3...6)
                if !model.sessionTemplates.isEmpty {
                    Picker("Template", selection: $templateId) {
                        Text("None").tag("")
                        ForEach(model.sessionTemplates) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Project", text: $cwd)
                Picker("Agent", selection: $provider) {
                    ForEach([ProviderId.claude, .codex], id: \.self) {
                        Text(Providers.spec(for: $0).label).tag($0)
                    }
                }
                AgentModelPicker(provider: provider, selection: $selectedModel).id(provider)
                Stepper("Round cap: \(roundCap)", value: $roundCap, in: 1...10)
                // shortcut: the budget rides in the prompt until juancode-8oa5.12's
                // per-chain budget field lands; then send it as that field instead.
                TextField("Token budget (optional)", text: $budget)
            }
            .formStyle(.grouped)
            .disabled(starting)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(starting).clickCursor()
                Button(starting ? "Starting…" : (error == nil ? "Start" : "Retry")) { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { cwd = seed.cwd }
        .onChange(of: provider) { _, _ in selectedModel = nil }
        .onChange(of: templateId) { _, id in
            guard let t = model.sessionTemplates.first(where: { $0.id == id }) else { return }
            cwd = t.cwd
            if t.provider == .claude || t.provider == .codex { provider = t.provider }
        }
    }

    private var prompt: String {
        var lines = [seed.epic.map { "Use the run-loop skill to drive bd epic \($0) to closed tickets." }
            ?? "Use the run-loop skill to take this goal from plan to closed tickets."]
        if !trimmedGoal.isEmpty { lines.append(seed.epic == nil ? "Goal: \(trimmedGoal)" : trimmedGoal) }
        lines.append("Round cap: \(roundCap).")
        if let tokens = Int(budget.filter(\.isNumber)), tokens > 0 {
            lines.append("Token budget for this chain: \(tokens) tokens. When the chain's total reaches it, "
                + "stop dispatching and chain_ask me before going on.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func start() {
        guard canStart, let url = URL(string: "\(SessionHandoff.sidecarBase)/api/dispatch") else { return }
        starting = true
        error = nil
        var body: [String: Any] = [
            "project": cwd.trimmingCharacters(in: .whitespaces), "prompt": prompt,
            "provider": provider.rawValue, "role": "orchestrator", "idempotencyKey": seed.id,
        ]
        if let epic = seed.epic { body["ticket"] = epic }
        if let selectedModel { body["model"] = selectedModel }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        Task { @MainActor in
            defer { starting = false }
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                self.error = "The Oracle sidecar at \(SessionHandoff.sidecarBase) didn't answer "
                    + "(\(error.localizedDescription)). Nothing was started; start it with `pnpm dev:oracle` and retry."
                return
            }
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // A live orchestrator on this epic already: go to it rather than make a second.
            let session = (reply?["sessionId"] ?? reply?["conflictingSessionId"]) as? String
            if reply?["ok"] as? Bool == true || session != nil {
                if let session { model.selection = session }
                else { model.errorMessage = (reply?["message"] as? String) ?? "Loop queued." }
                dismiss()
                return
            }
            self.error = (reply?["error"] as? String) ?? String(decoding: data, as: UTF8.self)
        }
    }
}
