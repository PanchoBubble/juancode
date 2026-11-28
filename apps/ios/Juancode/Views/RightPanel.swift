import SwiftUI

/// Wire shape of a tracked PR on `trackedPrs` frames (`TrackedPrWire` on the Mac side).
struct TrackedPrInfo: Decodable, Identifiable, Equatable {
    var id: String
    var number: Int
    var title: String
    var url: String
    var sessionId: String
    var state: String   // watching | fixing | needs_decision
    var checks: String  // passing | failing | pending | none
}

/// Oracle chat state; lives in RootView so closing the panel keeps the thread.
@MainActor @Observable
final class OracleChat {
    struct Message: Identifiable {
        let id = UUID()
        let mine: Bool
        var text: String
        var failed = false
    }
    var messages: [Message] = []
    var provider = "claude"
    var busy = false
    @ObservationIgnored private var threadId: String?

    func send(_ text: String, client: SidecarClient) async {
        messages.append(.init(mine: true, text: text))
        messages.append(.init(mine: false, text: ""))
        busy = true
        defer { busy = false }
        do {
            for try await ev in client.chat(text: text, sessionId: threadId, provider: provider) {
                switch ev {
                case .delta(let t): messages[messages.count - 1].text += t
                case .done(let id, let isError):
                    threadId = id ?? threadId
                    if isError { messages[messages.count - 1].failed = true }
                }
            }
        } catch {
            messages.append(.init(mine: false, text: error.localizedDescription, failed: true))
        }
        if messages[messages.count - 1].text.isEmpty { messages[messages.count - 1].text = "(no reply)" }
    }
}

/// Right panel: Oracle chat and tracked PRs.
struct RightPanel: View {
    let core: RemoteCore
    let chat: OracleChat
    let open: (String) -> Void
    @State private var tab = Tab.oracle
    enum Tab: String, CaseIterable { case oracle = "Oracle", prs = "PRs" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).padding()
            switch tab {
            case .oracle: OracleChatView(core: core, chat: chat)
            case .prs: PrListView(core: core, open: open)
            }
        }
    }
}

struct OracleChatView: View {
    let core: RemoteCore
    @Bindable var chat: OracleChat
    @State private var draft = ""

    private var client: SidecarClient? {
        core.pairing.oracle.map { SidecarClient(base: $0, token: core.pairing.token) }
    }

    var body: some View {
        if let client {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.messages) { m in
                            Text(m.text.isEmpty ? "…" : m.text)
                                .padding(10)
                                .background(m.mine ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(m.failed ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
                                .textSelection(.enabled)
                        }
                    }.padding(.horizontal)
                }
                Divider()
                HStack(alignment: .bottom) {
                    Picker("Agent", selection: $chat.provider) {
                        Text("claude").tag("claude")
                        Text("codex").tag("codex")
                    }.pickerStyle(.menu)
                    TextField("Ask the Oracle", text: $draft, axis: .vertical).lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button { send(client) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(chat.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding()
            }
        } else {
            ContentUnavailableView("No sidecar", systemImage: "bubble.left",
                                   description: Text("This pairing has no Oracle URL. Scan the QR again."))
        }
    }

    private func send(_ client: SidecarClient) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Task { await chat.send(text, client: client) }
    }
}

struct PrListView: View {
    let core: RemoteCore
    let open: (String) -> Void

    var body: some View {
        if core.trackedPrs.isEmpty {
            ContentUnavailableView("No tracked PRs", systemImage: "arrow.triangle.pull")
        } else {
            List(core.trackedPrs) { pr in
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(pr.number) \(pr.title)").lineLimit(2)
                    HStack {
                        Label(pr.state.replacingOccurrences(of: "_", with: " "), systemImage: "eye")
                        Label(pr.checks, systemImage: pr.checks == "failing" ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(pr.checks == "failing" ? .red : pr.checks == "passing" ? .green : .secondary)
                        Spacer()
                        if core.sessions.contains(where: { $0.id == pr.sessionId }) {
                            Button("Session") { open(pr.sessionId) }.buttonStyle(.bordered)
                        }
                        if let url = URL(string: pr.url) { Link("Open", destination: url) }
                    }.font(.caption)
                }
            }
        }
    }
}

/// Bell: only sessions waiting for input; tapping one opens it.
struct BellButton: View {
    let core: RemoteCore
    let open: (String) -> Void
    @State private var shown = false

    private var waiting: [SessionMetaRow] {
        core.sessions.filter { $0.status != .exited && core.activity[$0.id] == .waitingInput }
            .map { SessionMetaRow(id: $0.id, title: $0.title.isEmpty ? $0.provider.rawValue : $0.title) }
    }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: waiting.isEmpty ? "bell" : "bell.badge.fill")
        }
        .accessibilityLabel("\(waiting.count) waiting for input")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 0) {
                if waiting.isEmpty { Text("Nothing needs input").foregroundStyle(.secondary).padding() }
                ForEach(waiting) { s in
                    Button { shown = false; open(s.id) } label: {
                        Text(s.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                }
            }
            .frame(minWidth: 240).presentationCompactAdaptation(.popover)
        }
    }

    struct SessionMetaRow: Identifiable { let id: String; let title: String }
}
