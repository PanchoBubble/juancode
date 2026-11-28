import JuancodeWire
import SwiftUI

/// The + popover's body: an agent session on `cwd` (default) or the Oracle chat, and the
/// provider. Calls `open` once the core answers `created`.
struct NewSessionCard: View {
    let core: RemoteCore
    /// nil when no project is known yet (no sessions); only the Oracle is offered then.
    let cwd: String?
    let open: (String) -> Void
    let openOracle: () -> Void
    @State private var oracle = false
    @State private var provider = ProviderId.claude
    @State private var worktree = true
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New").font(.headline).foregroundStyle(Tok.text)
            if let cwd {
                choice(oracle: false, icon: "terminal", title: "Session in \((cwd as NSString).lastPathComponent)",
                       detail: "current project · default")
            }
            if core.pairing.oracle != nil {
                choice(oracle: true, icon: "bubble.left", title: "Oracle chat", detail: "ask across all sessions")
            }
            if !oracle, cwd != nil {
                Text("PROVIDER").font(.caption2).foregroundStyle(Tok.secondary)
                Picker("Provider", selection: $provider) {
                    Text("claude").tag(ProviderId.claude)
                    Text("codex").tag(ProviderId.codex)
                }
                .pickerStyle(.segmented)
                Toggle("Own worktree", isOn: $worktree).font(.subheadline).tint(Tok.blue)
            }
            if starting, let e = core.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            Button(action: start) {
                Text(oracle ? "Open Oracle" : starting ? "Starting…" : "Start session")
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(Tok.blue)
            .disabled(!oracle && (cwd == nil || starting && core.lastError == nil))
            if !oracle, cwd != nil {
                Text("Other project: ☰ → project → +").font(.caption2).foregroundStyle(Tok.secondary)
            }
        }
        .onAppear { if cwd == nil { oracle = true } }
    }

    private func choice(oracle value: Bool, icon: String, title: String, detail: String) -> some View {
        Button { withAnimation(.snappy) { oracle = value } } label: {
            HStack {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(Tok.text).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Tok.secondary)
                }
                Spacer()
                if oracle == value { Image(systemName: "checkmark").foregroundStyle(Tok.blue) }
            }
            .padding(10)
            .background(oracle == value ? Tok.surface2 : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func start() {
        if oracle { return openOracle() }
        guard let cwd else { return }
        starting = true
        core.onCreated = { open($0) }
        core.create(provider: provider, cwd: cwd, model: nil, worktree: worktree)
    }
}
