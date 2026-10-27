import SwiftUI
import MarkdownUI
import JuancodeCore
import JuancodeClient

/// Full working-tree document when available; otherwise render each diff hunk
/// independently so omitted lines cannot accidentally join paragraphs or fences.
struct ReviewMarkdownPreview: View {
    let file: DiffFile
    let cwd: String?
    let core: any CoreClient

    @State private var document: String?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading {
                    ProgressView("Loading Markdown…")
                } else if let document {
                    Text("Working-tree document").font(.caption).foregroundStyle(.secondary)
                    if document.isEmpty {
                        Text("This file is empty.").foregroundStyle(.secondary)
                    } else {
                        markdown(document)
                    }
                } else {
                    Text(file.status == .deleted
                         ? "Deleted document · changed sections only"
                         : "Changed sections only · after changes")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Unchanged sections are omitted. Formatting that starts outside a section may be incomplete.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure {
                        Text("Could not load the full document: \(failure)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let hunks = parseUnifiedDiff(file.diff)
                    if hunks.isEmpty {
                        Text("No Markdown content in this diff.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(hunk.header).font(.caption.monospaced()).foregroundStyle(.secondary)
                            let text = hunk.lines.filter {
                                file.status == .deleted ? $0.kind != .insert : $0.kind != .delete
                            }.map(\.text).joined(separator: "\n")
                            if text.isEmpty {
                                Text("This section is empty after the change.").foregroundStyle(.secondary)
                            } else {
                                markdown(text)
                            }
                        }
                        Divider()
                    }
                    if file.truncated {
                        Text("The diff was truncated; this preview is incomplete.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: "\(cwd ?? "")\u{0}\(file.path)\u{0}\(file.diff)") {
            document = nil
            failure = nil
            loading = cwd != nil
            guard let cwd else { return }
            do {
                let text = try await core.readFile(cwd: cwd, path: file.path)
                guard !Task.isCancelled else { return }
                document = text
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func markdown(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
