import SwiftUI
import JuancodeCore

/// Plain text only, explicitly identified as program-reported and tied to its pane.
struct ProgramStatusBadge: View {
    let feed: ProgramStatusFeed
    let source: String
    @State private var records: [ProgramStatusRecord] = []
    @State private var cancel: (@Sendable () -> Void)?

    var body: some View {
        Group {
            if let record = records.first {
                Text(verbatim: "Program · \(record.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(record.state == "blocked" || record.state == "error" ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .help("Program status from \(source)\n" + records.map {
                        "\($0.id.isEmpty ? "root" : $0.id): \($0.summary)"
                    }.joined(separator: "\n"))
            }
        }
        .onAppear {
            cancel = feed.observe { records in
                Task { @MainActor in self.records = records }
            }
        }
        .onDisappear { cancel?(); cancel = nil }
    }
}
