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

/// Oracle chat state; lives in RootView so closing the sheet keeps the thread.
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

struct OracleChatView: View {
    let core: RemoteCore
    @Bindable var chat: OracleChat
    @State private var draft = ""
    @State private var attachments = Attachments()

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
                AttachmentChips(attachments: attachments).padding(.top, 4)
                HStack(alignment: .bottom) {
                    Picker("Agent", selection: $chat.provider) {
                        Text("claude").tag("claude")
                        Text("codex").tag("codex")
                    }.pickerStyle(.menu)
                    AttachButton(attachments: attachments, client: client)
                    TextField("Ask the Oracle", text: $draft, axis: .vertical).lineLimit(1...4)
                        .composerField()
                    SendButton(disabled: chat.busy || attachments.busy
                               || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.paths.isEmpty)) {
                        send(client)
                    }
                }.padding()
            }
        } else {
            ContentUnavailableView("No sidecar", systemImage: "bubble.left",
                                   description: Text("This pairing has no Oracle URL. Scan the QR again."))
        }
    }

    private func send(_ client: SidecarClient) {
        let text = attachments.take(into: draft.trimmingCharacters(in: .whitespacesAndNewlines))
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
