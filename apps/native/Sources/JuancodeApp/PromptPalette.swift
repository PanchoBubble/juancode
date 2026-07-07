import SwiftUI
import JuancodeCore
import JuancodeServices

// MARK: - Prompt-template palette (juancode-2vd)
//
// A ⌘⇧K command palette for saved prompt templates — quick-insert reusable prompts
// into the active session's composer. These are juancode-side templates (stored in
// UserDefaults via `AppModel`), distinct from the CLI's own slash commands, which
// pass through the pty untouched.
//
// The palette has two modes: a search-and-pick list (default) and an editor for
// creating/editing one template. Picking a template inserts its body into the
// focused live session (Return) or inserts-and-submits it (⌘Return); if the current
// folder has no live session, a fresh Claude session is seeded with the prompt.

/// Presented as a sheet from `RootView`, toggled by `model.showingPromptPalette`
/// (⌘⇧K). Self-contained: owns the query + selection + edit state.
struct PromptPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    /// When non-nil the editor sheet is shown. `.new` creates, `.edit` updates.
    @State private var editing: EditTarget?
    @FocusState private var searchFocused: Bool

    private enum EditTarget: Identifiable {
        case new
        case edit(PromptTemplate)
        var id: String { switch self { case .new: "new"; case .edit(let t): t.id } }
    }

    private var results: [PromptTemplate] {
        filteredTemplates(model.promptTemplates, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.promptTemplates.isEmpty {
                emptyState
            } else if results.isEmpty {
                noMatches
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .sheet(item: $editing) { target in
            switch target {
            case .new: TemplateEditor(template: nil)
            case .edit(let t): TemplateEditor(template: t)
            }
        }
        // Keyboard-drive the list while the search field holds focus.
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { activateSelection(submit: false); return .handled }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { searchFocused = true }
    }

    // MARK: header / search

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "command").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search prompt templates…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { activateSelection(submit: false) }
            Button {
                editing = .new
            } label: {
                Label("New", systemImage: "plus")
            }
            .clickCursor()
            .help("Create a new prompt template")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, t in
                        row(t, selected: idx == selectedIndex)
                            .id(idx)
                            .onTapGesture { selectedIndex = idx; activateSelection(submit: false) }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func row(_ t: PromptTemplate, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title.isEmpty ? "Untitled" : t.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(t.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if selected {
                HStack(spacing: 4) {
                    Button { editTemplate(t) } label: { Image(systemName: "pencil") }
                        .help("Edit").clickCursor()
                    Button(role: .destructive) { model.deleteTemplate(t.id) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete").clickCursor()
                }
                .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 16) {
            PaletteKeyHint(key: "return", label: "Insert")
            PaletteKeyHint(key: "⌘ return", label: "Insert & send")
            Spacer()
            Button("Close") { dismiss() }.clickCursor()
                .keyboardShortcut(.cancelAction)
            // ⌘Return submits the highlighted template.
            Button("") { activateSelection(submit: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .font(.system(size: 11))
    }

    // MARK: empty / no-match

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
            Text("No saved templates yet.").foregroundStyle(.secondary).font(.system(size: 13))
            Text("Save a prompt you reuse — then ⌘⇧K to insert it into any session.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button { editing = .new } label: { Label("New Template", systemImage: "plus") }
                .clickCursor().padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No templates match \"\(query)\".").foregroundStyle(.secondary).font(.system(size: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func activateSelection(submit: Bool) {
        guard results.indices.contains(selectedIndex) else { return }
        let t = results[selectedIndex]
        if submit { model.submitTemplate(t) } else { model.insertTemplate(t) }
        dismiss()
    }

    private func editTemplate(_ t: PromptTemplate) { editing = .edit(t) }
}

/// Create/edit one template. `template == nil` creates a new one. Saving routes to
/// `AppModel.addTemplate` / `updateTemplate`; both persist immediately.
private struct TemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let template: PromptTemplate?

    @State private var title = ""
    @State private var body_ = ""

    private var canSave: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(template == nil ? "New Template" : "Edit Template").font(.title3).bold()
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("e.g. Write tests for this change", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $body_)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button(template == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave).clickCursor()
            }
        }
        .padding(20).frame(width: 460)
        .onAppear {
            title = template?.title ?? ""
            body_ = template?.body ?? ""
        }
    }

    private func save() {
        let titleToUse = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template {
            model.updateTemplate(template.id, title: titleToUse, body: body_)
        } else {
            model.addTemplate(title: titleToUse, body: body_)
        }
        dismiss()
    }
}
