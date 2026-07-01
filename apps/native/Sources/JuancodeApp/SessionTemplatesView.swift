import SwiftUI
import JuancodeCore
import JuancodeServices

/// Session templates launcher/manager (juancode-a2r). Lists saved launch presets
/// (agent + folder + knobs + optional seed prompt); each row launches one or N
/// sessions in a keystroke. Distinct from the ⌘K prompt palette (which reuses a
/// *prompt*) — this reuses the whole *launch*. Mirrors `PromptPaletteView`'s
/// list+editor shape and `NewSessionView`'s field set.
struct SessionTemplatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var editing: SessionTemplateEditor.Mode?

    private var results: [SessionTemplate] {
        filteredSessionTemplates(model.sessionTemplates, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Templates").font(.title2).bold()
                Spacer()
                Button {
                    editing = .create
                } label: {
                    Label("New", systemImage: "plus")
                }
                .clickCursor()
            }

            if !model.sessionTemplates.isEmpty {
                TextField("Search templates…", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            if model.sessionTemplates.isEmpty {
                emptyState
            } else if results.isEmpty {
                Text("No templates match \"\(query)\".")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(results) { t in row(t) }
                    }
                }
                .frame(minHeight: 200, maxHeight: 360)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
            }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $editing) { mode in
            SessionTemplateEditor(mode: mode)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No session templates yet.").font(.system(size: 13))
            Text("Save a starter config — agent, folder, and an optional prompt — then launch one or many sessions from it in a click.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    @ViewBuilder
    private func row(_ t: SessionTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name.isEmpty ? "Untitled" : t.name)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(Providers.spec(for: t.provider).label) · \(prettyCwd(t.cwd))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if t.skipPermissions {
                    tag("accept-all")
                }
                if t.isolateWorktree {
                    tag("worktree")
                }
            }
            if !t.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(t.initialPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                LaunchControl { count in
                    model.launchSessionTemplate(t, count: count)
                    dismiss()
                }
                Spacer()
                Button("Edit") { editing = .edit(t) }.controlSize(.small).clickCursor()
                Button(role: .destructive) { model.deleteSessionTemplate(t.id) } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small).clickCursor()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func prettyCwd(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// A "Launch" button with an inline copy-count stepper (1–8), so a template can
/// fan out N parallel sessions in one action.
private struct LaunchControl: View {
    let onLaunch: (Int) -> Void
    @State private var count = 1

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onLaunch(count)
            } label: {
                Label(count > 1 ? "Launch \(count)" : "Launch", systemImage: "play.fill")
            }
            .controlSize(.small).clickCursor()
            Stepper("", value: $count, in: 1...8).labelsHidden().controlSize(.small)
        }
    }
}

/// Create/edit one session template. Mirrors `NewSessionView`'s field set.
private struct SessionTemplateEditor: View {
    enum Mode: Identifiable {
        case create
        case edit(SessionTemplate)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let t): return t.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var provider: ProviderId = .claude
    @State private var cwd = Config.defaultCwd
    @State private var skipPermissions = true
    @State private var isolateWorktree = false
    @State private var initialPrompt = ""
    @State private var showingDirPicker = false

    private var editingId: String? {
        if case .edit(let t) = mode { return t.id }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cwd.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingId == nil ? "New Template" : "Edit Template").font(.title3).bold()
            Form {
                TextField("Name", text: $name)
                Picker("Agent", selection: $provider) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        Text(Providers.spec(for: p).label).tag(p)
                    }
                }
                HStack {
                    TextField("Working directory", text: $cwd)
                    Button("Choose…") { showingDirPicker = true }.clickCursor()
                }
                Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
                Toggle("Isolate each session in a fresh git worktree", isOn: $isolateWorktree)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Initial prompt (optional)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $initialPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button(editingId == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave).clickCursor()
            }
        }
        .padding(20).frame(width: 480)
        .fileImporter(isPresented: $showingDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let needsScope = url.startAccessingSecurityScopedResource()
                cwd = url.path
                if needsScope { url.stopAccessingSecurityScopedResource() }
            }
        }
        .onAppear {
            if case .edit(let t) = mode {
                name = t.name
                provider = t.provider
                cwd = t.cwd
                skipPermissions = t.skipPermissions
                isolateWorktree = t.isolateWorktree
                initialPrompt = t.initialPrompt
            }
        }
    }

    private func save() {
        if let id = editingId {
            model.updateSessionTemplate(id, name: name, provider: provider, cwd: cwd,
                                        skipPermissions: skipPermissions,
                                        isolateWorktree: isolateWorktree, initialPrompt: initialPrompt)
        } else {
            model.addSessionTemplate(name: name, provider: provider, cwd: cwd,
                                     skipPermissions: skipPermissions,
                                     isolateWorktree: isolateWorktree, initialPrompt: initialPrompt)
        }
        dismiss()
    }
}
