// Settings → Shortcuts pane (juancode-oe4). Lists every rebindable command with
// its current key + modifiers; each is editable (toggle the modifier chips, type
// the key) and resettable to its default. Surfaced via the standard ⌘, window.

import SwiftUI

struct ShortcutSettingsView: View {
    @Environment(Shortcuts.self) private var shortcuts
    @State private var query = ""

    private var filteredActions: [ShortcutAction] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutAction.allCases.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Reset All") { shortcuts.resetAll() }
                    .disabled(ShortcutAction.allCases.allSatisfy { shortcuts.isDefault($0) })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a command…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Find a keyboard shortcut")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear shortcut search")
                    .help("Clear search")
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(filteredActions.enumerated()), id: \.element.id) { idx, action in
                        ShortcutRow(action: action)
                        if idx < filteredActions.count - 1 { Divider() }
                    }
                    if filteredActions.isEmpty {
                        Text("No matching commands. Try “session”, “terminal”, or “editor”.")
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
            }

            Divider()
            Text("Type a single letter, or “space”. A shortcut needs at least one modifier.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 520, height: 420)
    }
}

private struct ShortcutRow: View {
    @Environment(Shortcuts.self) private var shortcuts
    let action: ShortcutAction

    /// Local mirror of the key field so the user can type "space" without each
    /// keystroke being normalized away; committed on submit / focus loss.
    @State private var keyText = ""
    @FocusState private var keyFocused: Bool

    private var binding: KeyBinding { shortcuts.binding(for: action) }
    private var conflicts: [ShortcutAction] { shortcuts.conflicts(for: action) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let first = conflicts.first {
                    Label("Conflicts with “\(first.title)”", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !binding.isBound {
                    Text("No modifier — not active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            modChip("⌃", \.control)
            modChip("⌥", \.option)
            modChip("⇧", \.shift)
            modChip("⌘", \.command)

            TextField("key", text: $keyText)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit { commitKey() }
                .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }

            Button {
                shortcuts.reset(action)
                keyText = displayKey(shortcuts.binding(for: action).key)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default (\(action.defaultBinding.display))")
            .disabled(shortcuts.isDefault(action))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { keyText = displayKey(binding.key) }
        .onChange(of: binding.key) { _, key in keyText = displayKey(key) }
    }

    private func modChip(_ symbol: String, _ keyPath: WritableKeyPath<KeyBinding, Bool>) -> some View {
        let on = binding[keyPath: keyPath]
        return Button(symbol) {
            var b = binding
            b[keyPath: keyPath].toggle()
            shortcuts.setBinding(b, for: action)
        }
        .buttonStyle(.bordered)
        .tint(on ? .accentColor : nil)
        .frame(width: 32)
    }

    /// "space" shows as "space" in the field; a single char shows uppercased.
    private func displayKey(_ key: String) -> String {
        key == "space" ? "space" : key.uppercased()
    }

    private func commitKey() {
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized: String
        if trimmed == "space" || trimmed == " " {
            normalized = "space"
        } else if let last = trimmed.last {
            normalized = String(last)
        } else {
            normalized = ""
        }
        var b = binding
        b.key = normalized
        shortcuts.setBinding(b, for: action)
        keyText = displayKey(normalized)
    }
}
