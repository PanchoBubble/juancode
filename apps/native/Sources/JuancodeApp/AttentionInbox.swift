import SwiftUI
import JuancodeCore

struct AttentionButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.supportsAttention {
            Button { model.showingAttention = true } label: {
                Label("Inbox \(model.activeAttention.count)", systemImage: "tray")
            }
            .help("Open the session attention inbox")
        }
    }
}

struct AttentionInbox: View {
    @Environment(OracleModel.self) private var oracle
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = "all"
    @State private var error: String?
    @State private var pending: Set<String> = []
    private var items: [AttentionItem] {
        model.activeAttention.filter { filter == "all" || $0.kind == filter }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Attention inbox").font(.title2)
                Spacer()
                Button("Open oldest") { if let item = items.first { open(item) } }
                    .disabled(items.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Show", selection: $filter) {
                Text("All (\(model.activeAttention.count))").tag("all")
                ForEach(["waiting", "error", "completion"], id: \.self) { kind in
                    Text("\(kind.capitalized) (\(model.activeAttention.filter { $0.kind == kind }.count))").tag(kind)
                }
            }.pickerStyle(.segmented)
            if let error { Text(error).foregroundStyle(.red) }
            if model.attentionItems == nil {
                Text("Inbox unavailable. Waiting for the daemon’s snapshot.").foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("No sessions need attention in this view.").foregroundStyle(.secondary)
            }
            List(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(model.sessions.first { $0.id == item.sessionId }?.title ?? item.sessionId)
                        Text(Date(timeIntervalSince1970: Double(item.createdAt) / 1000), style: .relative)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open session") { open(item) }
                    if item.kind != "waiting" {
                        Button("Mark read") { acknowledge(item) }.disabled(pending.contains(item.id))
                    }
                }.padding(.vertical, 4)
            }
            Text("Questions and approvals are answered in the session. Mark read only acknowledges this inbox item.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 620, minHeight: 400)
    }
    private func acknowledge(_ item: AttentionItem) {
        pending.insert(item.id)
        Task {
            defer { pending.remove(item.id) }
            do { try await model.acknowledgeAttention(item.id) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func open(_ item: AttentionItem) {
        guard let meta = model.sessions.first(where: { $0.id == item.sessionId }) else {
            error = "This session is no longer available."
            return
        }
        model.unhideProject(meta.cwd)
        model.unhideProject(projectCwd(for: meta.cwd))
        if model.isOracleSession(item.sessionId) {
            oracle.reveal()
            oracle.selectOracle(item.sessionId)
        } else {
            model.revealSession(item.sessionId)
            model.focusTerminal()
        }
        dismiss()
    }
}
