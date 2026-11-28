import SwiftTerm
import AVFoundation
import SwiftUI

/// One session: the terminal, a key row for what the soft keyboard lacks, and an
/// input bar that sends a line plus Enter.
struct SessionView: View {
    let core: RemoteCore
    let sessionId: String
    @State private var line = ""
    @State private var alerts: AlertsState?
    @State private var recorder = VoiceRecorder()
    @State private var transcribing = false
    @State private var voiceError: String?
    @State private var attachments = Attachments()

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
                    // Resigns whichever holds the keyboard (the field or the terminal); the dock
                    // comes back on keyboardWillHide.
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Hide keyboard")
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
            if let voiceError { Text(voiceError).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
            AttachmentChips(attachments: attachments)
            HStack(alignment: .bottom, spacing: 6) {
                if let oracle = core.pairing.oracle {
                    if recorder.isRecording || transcribing {
                        stopButton
                    } else {
                        AttachButton(attachments: attachments, client: SidecarClient(base: oracle, token: core.pairing.token),
                                     voice: startRecording)
                    }
                }
                TextField("Message", text: $line, axis: .vertical)
                    .lineLimit(1...4)
                    .composerField()
                SendButton(disabled: attachments.busy || (line.isEmpty && attachments.paths.isEmpty)) {
                    core.submit(sessionId, attachments.take(into: line))
                    line = ""
                }
            }
            .padding(8)
        }
        .navigationTitle(core.sessions.first { $0.id == sessionId }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if core.pairing.oracle != nil { ToolbarItem(placement: .topBarTrailing) { alertsMenu } } }
        .task { alerts = try? await AlertsClient.fetch(core.pairing) }
        // A dead (killed or vanished) session must not keep the keyboard up: the dock hides under it,
        // leaving no way to leave the session.
        .onChange(of: core.sessions.first { $0.id == sessionId }?.status != .running, initial: true) { _, dead in
            if dead { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
    }

    private func startRecording() {
        voiceError = nil
        Task { if !(await recorder.start()) { voiceError = "Microphone access is off for juancode." } }
    }

    /// Shown while recording (from + → Voice): tap to stop; the Mac's Whisper transcribes it into
    /// the field for editing.
    private var stopButton: some View {
        Button {
            guard let url = recorder.stop(), let oracle = core.pairing.oracle else { return }
            transcribing = true
            Task {
                defer { transcribing = false; try? FileManager.default.removeItem(at: url) }
                do {
                    let client = SidecarClient(base: oracle, token: core.pairing.token)
                    let text = try await client.transcribe(m4a: Data(contentsOf: url))
                    line += (line.isEmpty || text.isEmpty ? "" : " ") + text
                } catch { voiceError = error.localizedDescription }
            }
        } label: {
            Group {
                if transcribing { ProgressView() } else { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
            }
            .composerIcon()
            .symbolEffect(.pulse, isActive: recorder.isRecording)
        }
        .disabled(transcribing)
        .accessibilityLabel(transcribing ? "Transcribing" : "Stop recording")
    }

    /// Per-session push toggle, plus the ntfy topic to subscribe to in the ntfy app.
    private var alertsMenu: some View {
        let on = !(alerts?.muted.contains(sessionId) ?? false)
        return Menu {
            Button {
                Task {
                    if let next = try? await AlertsClient.setEnabled(core.pairing, sessionId: sessionId, enabled: !on) {
                        alerts = next
                    }
                }
            } label: {
                Label(on ? "Alerts on for this session" : "Alerts muted", systemImage: on ? "bell.fill" : "bell.slash")
            }
            if let topic = alerts?.topic {
                Section("ntfy topic") {
                    Button(topic) { UIPasteboard.general.string = topic }
                    if let url = URL(string: "ntfy://ntfy.sh/\(topic)") { Link("Open in ntfy", destination: url) }
                }
            }
        } label: {
            Image(systemName: on ? "bell.fill" : "bell.slash").accessibilityLabel("Phone alerts")
        }
        .disabled(alerts == nil)
    }
}

/// SwiftTerm view fed by `attached` + `output`; what it types goes back as `input`.
///
/// The pty has one grid, owned by the first client to size it (juancoded `GridState`). When the Mac
/// owns it the phone's resize is denied, and bytes drawn for the Mac's width garble a phone-width
/// emulator. So the phone lays its terminal out at the owner's grid and zooms it to fit (pinch to
/// read); only when the grid is free or its own does it size the pty to the phone.
private struct TerminalPane: UIViewRepresentable {
    let core: RemoteCore
    let sessionId: String

    func makeCoordinator() -> Coordinator { Coordinator(core: core, sessionId: sessionId) }

    func makeUIView(context: Context) -> TerminalHost {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.keyboardDismissMode = .interactive
        let host = TerminalHost(term: view)
        host.follow = core.foreignGrid[sessionId]
        context.coordinator.host = host
        // With the keyboard up a tap closes it; SwiftTerm's own tap (focus, clicks) waits for this
        // one to fail, which it does at once while the keyboard is down.
        let dismiss = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        dismiss.delegate = context.coordinator
        view.addGestureRecognizer(dismiss)
        for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? [] where tap !== dismiss {
            tap.require(toFail: dismiss)
        }
        let id = sessionId
        core.onTerminalBytes = { [weak view] sid, bytes in
            guard sid == id else { return }
            view?.feed(byteArray: bytes[...])
        }
        core.onGrid = { [weak coordinator = context.coordinator] sid, grid in
            guard sid == id else { return }
            coordinator?.follow(grid)
        }
        return host
    }

    func updateUIView(_ view: TerminalHost, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, UIGestureRecognizerDelegate {
        let core: RemoteCore
        let sessionId: String
        weak var host: TerminalHost?
        private var attached = false
        private var keyboardUp = false

        init(core: RemoteCore, sessionId: String) {
            self.core = core
            self.sessionId = sessionId
            super.init()
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(keyboardShown), name: UIResponder.keyboardWillShowNotification, object: nil)
            nc.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        @objc private func keyboardShown() { keyboardUp = true }
        @objc private func keyboardHidden() { keyboardUp = false }
        @objc func dismissKeyboard() { host?.window?.endEditing(true) }
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { keyboardUp }

        /// Another client took the grid (lay out at it), or it is free or ours again (claim it at
        /// the phone's size; SwiftTerm only reports a size that changed, so send it explicitly).
        func follow(_ grid: (cols: Int, rows: Int)?) {
            guard let host else { return }
            let wasFollowing = host.follow != nil
            host.follow = grid
            host.layoutIfNeeded()
            if grid == nil, wasFollowing, attached {
                let t = host.term.terminalDimensions
                core.resize(sessionId, cols: t.cols, rows: t.rows)
            }
        }

        /// The first real size attaches; later ones resize, unless they are the owner's grid we follow.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            if !attached {
                attached = true
                core.attach(sessionId, cols: newCols, rows: newRows)
            } else if host?.follow == nil {
                core.resize(sessionId, cols: newCols, rows: newRows)
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

/// Holds the terminal. Filling the view while the phone drives the grid; at a foreign grid it is
/// laid out at that size and zoomed out to fit the width, pinch-zoomable up to the native font.
final class TerminalHost: UIScrollView, UIScrollViewDelegate {
    let term: TerminalView
    var follow: (cols: Int, rows: Int)? { didSet { laidOut = nil; setNeedsLayout() } }
    /// What the last layout was for, so scroll and zoom passes do not reset the zoom.
    private var laidOut: (width: CGFloat, cols: Int, rows: Int)?

    init(term: TerminalView) {
        self.term = term
        super.init(frame: .zero)
        delegate = self
        bouncesZoom = false
        keyboardDismissMode = .interactive
        showsHorizontalScrollIndicator = false
        backgroundColor = term.nativeBackgroundColor
        addSubview(term)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { follow == nil ? nil : term }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let grid = follow else {
            zoomScale = 1
            minimumZoomScale = 1
            maximumZoomScale = 1
            term.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            return
        }
        if let l = laidOut, l.width == bounds.width, l.cols == grid.cols, l.rows == grid.rows { return }
        laidOut = (bounds.width, grid.cols, grid.rows)
        zoomScale = 1
        let t = term.terminalDimensions
        if t.cols != grid.cols || t.rows != grid.rows { term.resize(cols: grid.cols, rows: grid.rows) }
        let exact = term.getOptimalFrameSize().size
        // Half a cell of slack, so SwiftTerm's own layout pass floors to this same grid.
        let size = CGSize(width: exact.width + exact.width / CGFloat(grid.cols) / 2,
                          height: exact.height + exact.height / CGFloat(grid.rows) / 2)
        term.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = min(1, bounds.width / size.width)
        maximumZoomScale = max(1.5, minimumZoomScale)
        zoomScale = minimumZoomScale
    }
}

/// Records AAC/m4a to a temp file while the mic button is held.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private var rec: AVAudioRecorder?
    private var releasedEarly = false

    /// false when the mic is denied (or the recorder would not start). A release that lands
    /// while the permission prompt is up cancels the start.
    func start() async -> Bool {
        releasedEarly = false
        guard await AVAudioApplication.requestRecordPermission(), !releasedEarly else { return !releasedEarly }
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            ])
            guard r.record() else { return false }
            rec = r
            isRecording = true
            return true
        } catch { return false }
    }

    /// The finished recording, or nil if nothing was recording or it was a sub-half-second tap.
    func stop() -> URL? {
        releasedEarly = true
        guard let r = rec else { return nil }
        let long = r.currentTime >= 0.5
        r.stop()
        rec = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        if !long { try? FileManager.default.removeItem(at: r.url) }
        return long ? r.url : nil
    }
}
