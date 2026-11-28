import SwiftTerm
import SwiftUI

/// One session: the terminal, a key row for what the soft keyboard lacks, and an
/// input bar that sends a line plus Enter.
struct SessionView: View {
    let core: RemoteCore
    let sessionId: String
    @State private var line = ""

    private static let keyRow: [(label: String, keys: [String]?, text: String?)] = [
        ("Esc", ["Escape"], nil), ("↑", ["Up"], nil), ("↓", ["Down"], nil),
        ("←", ["Left"], nil), ("→", ["Right"], nil), ("^C", ["C-c"], nil),
        ("Tab", ["Tab"], nil), ("y", nil, "y"), ("n", nil, "n"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TerminalPane(core: core, sessionId: sessionId)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.keyRow, id: \.label) { k in
                        Button(k.label) {
                            if let keys = k.keys { core.keys(sessionId, keys) }
                            if let text = k.text { core.input(sessionId, text) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 4)
            HStack {
                TextField("Message", text: $line, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    core.input(sessionId, line)
                    core.keys(sessionId, ["Enter"])
                    line = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .accessibilityLabel("Send")
                    .disabled(line.isEmpty)
            }
            .padding(8)
        }
        .navigationTitle(core.sessions.first { $0.id == sessionId }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// SwiftTerm view fed by `attached` + `output`; what it types goes back as `input`.
private struct TerminalPane: UIViewRepresentable {
    let core: RemoteCore
    let sessionId: String

    func makeCoordinator() -> Coordinator { Coordinator(core: core, sessionId: sessionId) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        context.coordinator.view = view
        let id = sessionId
        core.onTerminalBytes = { [weak view] sid, bytes in
            guard sid == id else { return }
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let core: RemoteCore
        let sessionId: String
        weak var view: TerminalView?
        private var attached = false

        init(core: RemoteCore, sessionId: String) {
            self.core = core
            self.sessionId = sessionId
        }

        /// The first real size attaches; later ones resize.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            if attached {
                core.resize(sessionId, cols: newCols, rows: newRows)
            } else {
                attached = true
                core.attach(sessionId, cols: newCols, rows: newRows)
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            core.input(sessionId, String(decoding: data, as: UTF8.self))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
