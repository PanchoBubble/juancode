import JuancodeCore
import JuancodeDesktop
import SwiftUI

/// What ⌘⇧N (and the toolbar "+") presents. With a session selected it is the
/// compact provider chooser — pick an agent with ↑/↓, ⏎ starts it in that session's
/// project — and "More options…" swaps in the full `NewSessionView`, pre-filled.
/// With nothing selected there is no project to clone, so the full form opens directly.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    /// Fixed when the sheet opens: the selection moving underneath it (a spawn
    /// finishing elsewhere) must not retarget or reset what the user is choosing.
    @State private var seed: NewSessionTarget?
    @State private var resolved = false
    @State private var fullForm = false

    var body: some View {
        Group {
            if !resolved {
                Color.clear.frame(width: 1, height: 1)
            } else if let seed, !fullForm {
                ProviderChooserView(seed: seed, moreOptions: { fullForm = true })
            } else if let seed {
                NewSessionView(provider: seed.provider, cwd: seed.cwd)
            } else {
                NewSessionView()
            }
        }
        .onAppear {
            guard !resolved else { return }
            seed = model.newSessionTarget()
            resolved = true
        }
    }
}

/// The compact half of `NewSessionSheet`: one row per registered provider, starting
/// on the selected session's agent. ⏎ creates exactly one session through
/// `createInFolder` — the same spawn path, permission default and per-project
/// worktree default as ⌘N — and ⎋ closes without spawning.
struct ProviderChooserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let seed: NewSessionTarget
    let moreOptions: () -> Void

    @State private var provider: ProviderId
    /// Latched on the first ⏎ so a repeat before the sheet is gone can't spawn twice.
    @State private var started = false
    @FocusState private var focused: Bool

    private let providers = ProviderId.allCases

    init(seed: NewSessionTarget, moreOptions: @escaping () -> Void) {
        self.seed = seed
        self.moreOptions = moreOptions
        _provider = State(initialValue: seed.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session").font(.title3).bold()
                Text(folderCaption)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            VStack(spacing: 2) {
                ForEach(providers, id: \.self) { p in row(p) }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            HStack {
                Button("More options…", action: moreOptions)
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Opening prompt, folder, worktree and permission settings (⌘O)")
                    .clickCursor()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(started)
                    .clickCursor()
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func row(_ p: ProviderId) -> some View {
        let selected = p == provider
        return Button {
            provider = p
            start()
        } label: {
            HStack(spacing: 8) {
                ProviderIcon(provider: p, size: 14, tint: selected ? .white : .secondary)
                Text(Providers.spec(for: p).label)
                Spacer()
                if let note = unavailableNote(p) {
                    Text(note).font(.system(size: 11))
                        .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    /// Only from a status check already run elsewhere — checking here would shell
    /// into every CLI just to open the chooser.
    private func unavailableNote(_ p: ProviderId) -> String? {
        guard let status = model.providerStatus?.first(where: { $0.id == p }),
              !status.available else { return nil }
        return "not found"
    }

    private var folderCaption: String {
        let name = (seed.cwd as NSString).lastPathComponent
        return seed.isolateWorktree ? "\(name) · new worktree" : name
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        provider = ProviderChoice.step(provider, by: delta, in: providers)
        return .handled
    }

    private func start() {
        guard !started else { return }
        started = true
        model.createInFolder(provider: provider, cwd: seed.cwd, isolateWorktree: seed.isolateWorktree)
        dismiss()
    }
}
