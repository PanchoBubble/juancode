import SwiftUI
import JuancodeCore

// The chain's notes column: the agents' latest summary on top, then the running log
// (your requests and the swarm's notes), and a field to add one. The file belongs to
// the sidecar (see JuancodeCore/ChainNotes.swift); this view re-reads it while shown.

struct ChainNotesPanel: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    @State private var notes: [ChainNote] = []
    @State private var draft = ""
    @State private var asSummary = false
    @State private var error: String?

    var body: some View {
        let summary = notes.last(where: \.isSummary)
        let log = notes.filter { !$0.isSummary }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOTES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(log.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
            if let summary {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Summary", systemImage: "text.badge.star")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Text(summary.text).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(author(summary)) · \(relativeTime(summary.at))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if log.isEmpty {
                            Text("Nothing yet. Requests you add here, and notes agents post with chain_note, stay with the chain.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(log) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: note.byYou ? "person.fill" : "terminal")
                                        .font(.system(size: 9))
                                    Text(author(note)).lineLimit(1)
                                    Spacer()
                                    Text(relativeTime(note.at))
                                }
                                .font(.caption2)
                                .foregroundStyle(note.byYou ? Color.accentColor : .secondary)
                                Text(note.text).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(note.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                .onChange(of: log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextField(asSummary ? "Set the summary" : "Add a note or request", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(add)
                HStack {
                    Toggle("Summary", isOn: $asSummary)
                        .toggleStyle(.checkbox).font(.caption)
                        .help("Replace the chain's headline summary instead of adding to the log")
                    if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                    Spacer()
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .background(Color.appPanel)
        // Agents write through the sidecar; a cheap re-read is enough to follow them.
        .task(id: chain.id) {
            while !Task.isCancelled {
                let loaded = ChainNotes.read(chainId: chain.id)
                if loaded != notes { notes = loaded }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func author(_ note: ChainNote) -> String {
        if note.byYou { return "You" }
        if let name = model.sessions.first(where: { $0.id == note.author })?.title, !name.isEmpty { return name }
        return note.authorName ?? String(note.author.prefix(8))
    }

    private func add() {
        do {
            try ChainNotes.append(chainId: chain.id, text: draft, summary: asSummary)
            draft = ""
            asSummary = false
            error = nil
            notes = ChainNotes.read(chainId: chain.id)
        } catch {
            self.error = "Could not save the note"
        }
    }
}
