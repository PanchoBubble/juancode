import SwiftUI
import AppKit
import GhosttyTerminal
import JuancodeCore
import JuancodeServices

/// SPIKE (juancode bd: replace SwiftTerm with GhosttyKit): a drop-in alternative
/// to `SwiftTermLive`, rendering the live pty with libghostty's GPU surface instead
/// of SwiftTerm's CoreGraphics one. Same public `View` interface so the call site
/// can A/B between them behind `JUANCODE_GHOSTTY=1`.
///
/// The architecture is preserved: *we* own the pty (local `forkpty` / remote
/// `node-pty`); libghostty's `InMemoryTerminalSession` is a host-driven backend —
/// pty output is pushed in via `receive(_:)`, user input comes back via the `write`
/// callback, and grid changes arrive via the resize delegate → our SIGWINCH. No
/// process is spawned by Ghostty.
/// Which terminal surface the live panes use. GhosttyKit (libghostty) is the
/// default; set `JUANCODE_SWIFTTERM=1` to fall back to SwiftTerm for comparison.
enum TerminalBackendChoice {
    static var useGhostty: Bool {
        ProcessInfo.processInfo.environment["JUANCODE_SWIFTTERM"] != "1"
    }
}

/// Marker for "the first responder is one of our live terminal surfaces", adopted
/// by both SwiftTerm's `TerminalView` and Ghostty's `AppTerminalView`. The
/// window-level key monitor (`installPaneNavigation`) uses this to tell "in the
/// terminal" from "in the sidebar" without hard-coding one backend's view class —
/// otherwise keystrokes into the Ghostty surface get swallowed as sidebar nav.
protocol JuancodeTerminalResponder {}
extension AppTerminalView: JuancodeTerminalResponder {}

/// Ghostty theme for our live panes. The app runs in forced dark mode (see
/// `RootView`), so only the dark variant is ever used — start from libghostty's
/// `afterglow` and override the background to pure black (afterglow ships #212121).
/// Last-wins config rendering means the appended `background` overrides the base.
private let juancodeGhosttyTheme = TerminalTheme(
    light: .alabaster,
    dark: .afterglow.background("000000")
)

struct GhosttyLive: View {
    let session: Session
    var remembersSize: Bool = true
    var focusToken: Int = 0
    var autoFocusOnAppear: Bool = true

    var body: some View {
        GeometryReader { proxy in
            GhosttyRepresentable(session: session, targetSize: proxy.size,
                                 remembersSize: remembersSize, focusToken: focusToken,
                                 autoFocusOnAppear: autoFocusOnAppear)
        }
    }
}

/// Hosts libghostty's `AppTerminalView`, pinning it to our bounds and driving
/// `fitToSize()` on every layout — the same single-source-of-truth resize strategy
/// `TerminalHostView` uses for SwiftTerm. `fitToSize()` measures the view's real
/// bounds, recomputes the grid, and fires the resize delegate, which is where the
/// pty SIGWINCH flows from.
final class GhosttyHostView: NSView {
    let terminal: TerminalView
    var onDrop: ((String) -> Void)?
    var focusOnAppear = false
    private var didAutoFocus = false

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = []
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.frame = bounds
        addSubview(terminal)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, !didAutoFocus, window != nil else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    /// Pin the surface to our exact bounds, then let Ghostty re-measure. Unlike
    /// SwiftTerm we don't poke `needsDisplay` — the Metal surface schedules its own
    /// redraw from `fitToSize()`'s immediate tick.
    private func pin() {
        if terminal.frame != bounds { terminal.frame = bounds }
        terminal.fitToSize()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); pin() }
    override func layout() { super.layout(); pin() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); pin() }

    func applySize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let f = NSRect(origin: .zero, size: size)
        if terminal.frame != f { terminal.frame = f }
        terminal.fitToSize()
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && !droppedPaths(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        guard let onDrop, !paths.isEmpty else { return false }
        onDrop(paths.map(ghosttyShellQuote).joined(separator: " ") + " ")
        return true
    }

    private func droppedPaths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.map(\.path)
    }
}

private func ghosttyShellQuote(_ path: String) -> String {
    if path.range(of: "[^A-Za-z0-9_./-]", options: .regularExpression) == nil { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct GhosttyRepresentable: NSViewRepresentable {
    let session: Session
    var targetSize: CGSize
    var remembersSize: Bool
    var focusToken: Int = 0
    var autoFocusOnAppear: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(session: session, remembersSize: remembersSize) }

    func makeNSView(context: Context) -> GhosttyHostView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        context.coordinator.attach(to: tv)
        let host = GhosttyHostView(terminal: tv)
        host.focusOnAppear = autoFocusOnAppear
        host.onDrop = { [session] text in session.write(text) }
        return host
    }

    func updateNSView(_ nsView: GhosttyHostView, context: Context) {
        nsView.applySize(targetSize)
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.focusTerminal()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GhosttyHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }

    static func dismantleNSView(_ nsView: GhosttyHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceResizeDelegate, TerminalSurfaceBellDelegate,
                             TerminalSurfaceLifecycleDelegate {
        private let session: Session
        private weak var view: TerminalView?
        private var gsession: InMemoryTerminalSession?
        private var cancel: (() -> Void)?
        private var streaming = false
        private var resizeWork: DispatchWorkItem?
        private var lastSent: (cols: Int, rows: Int)?
        private let remembersSize: Bool
        var lastFocusToken = 0

        init(session: Session, remembersSize: Bool) {
            self.session = session
            self.remembersSize = remembersSize
        }

        func attach(to tv: TerminalView) {
            view = tv
            let session = self.session
            // User input (keystrokes the surface produced) → our pty.
            let gs = InMemoryTerminalSession(
                write: { data in session.write([UInt8](data)) },
                resize: { _ in } // grid handled via the resize delegate below
            )
            gsession = gs
            // The surface is built lazily by `rebuildIfReady()`, which bails unless a
            // controller is set — without this nothing ever renders and every
            // `receive()` is dropped. Mirrors the example app's `terminalView.controller`.
            tv.controller = TerminalController(theme: juancodeGhosttyTheme)
            tv.configuration = TerminalSurfaceOptions(backend: .inMemory(gs))
            tv.delegate = self
            // NB: we deliberately do NOT subscribe to the pty yet. The surface is
            // created lazily once the view enters a window; `receive()` drops bytes
            // while the surface is nil, so an early scrollback replay would vanish.
            // Streaming starts from `terminalDidAttachSurface` instead.
        }

        // MARK: TerminalSurfaceLifecycleDelegate

        /// Surface is live — now it's safe to replay scrollback + stream live output.
        func terminalDidAttachSurface(_: TerminalSurface) {
            guard !streaming else { return }
            streaming = true
            // Replay scrollback then stream live output, pushed into the surface.
            // The pty callback is on a background queue; surface writes must be on main.
            cancel = session.subscribeOutput(replay: true) { [weak gsession] bytes in
                let data = Data(bytes)
                DispatchQueue.main.async {
                    PerfMonitor.recordFeed(bytes.count)
                    gsession?.receive(data)
                }
            }
        }

        func terminalDidDetachSurface() {}

        func detach() {
            resizeWork?.cancel(); resizeWork = nil
            cancel?(); cancel = nil
            streaming = false
            gsession = nil
        }

        // MARK: TerminalSurfaceResizeDelegate

        /// Ghostty measured a new grid for the current bounds. Debounce a SIGWINCH
        /// so a resize burst (divider drag, panel toggle) collapses to one repaint,
        /// and remember the size as the next spawn grid — mirrors SwiftTermLive.
        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.sendResize(cols: columns, rows: rows) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: work)
        }

        private func sendResize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            if remembersSize { TerminalGrid.remember(cols: cols, rows: rows) }
            if let last = lastSent, last.cols == cols, last.rows == rows { return }
            lastSent = (cols, rows)
            session.resize(cols: cols, rows: rows)
        }

        // MARK: misc delegates

        func terminalDidRingBell() { NSSound.beep() }
    }
}

/// Ghostty counterpart of `SwiftTermEphemeral`: drives the libghostty surface from a
/// live `EphemeralPty` (a `$SHELL -i` for the bottom terminal panel / editor). Unlike
/// `Session`, an `EphemeralPty` has no scrollback replay — its first output (the shell
/// prompt) can arrive before the surface is created, and `receive()` drops bytes while
/// the surface is nil. So we buffer pre-surface output and flush it on attach.
struct GhosttyEphemeral: NSViewRepresentable {
    let pty: EphemeralPty
    let onExit: @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pty: pty, onExit: onExit) }

    func makeNSView(context: Context) -> GhosttyHostView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        context.coordinator.attach(to: tv)
        let host = GhosttyHostView(terminal: tv)
        host.focusOnAppear = true
        host.onDrop = { [pty] text in pty.write(Array(text.utf8)) }
        return host
    }

    func updateNSView(_ nsView: GhosttyHostView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GhosttyHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }

    static func dismantleNSView(_ nsView: GhosttyHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceResizeDelegate, TerminalSurfaceBellDelegate,
                             TerminalSurfaceLifecycleDelegate {
        private let pty: EphemeralPty
        private let onExit: @Sendable () -> Void
        private weak var view: TerminalView?
        private var gsession: InMemoryTerminalSession?
        private var cancelOutput: (() -> Void)?
        private var cancelExit: (() -> Void)?
        private var resizeWork: DispatchWorkItem?
        private var lastSent: (cols: Int, rows: Int)?
        /// Output that arrived before the surface existed; flushed on attach.
        private var preSurfaceBuffer: [UInt8] = []
        private var surfaceReady = false

        init(pty: EphemeralPty, onExit: @escaping @Sendable () -> Void) {
            self.pty = pty
            self.onExit = onExit
        }

        func attach(to tv: TerminalView) {
            view = tv
            let pty = self.pty
            let gs = InMemoryTerminalSession(
                write: { data in pty.write([UInt8](data)) },
                resize: { _ in }
            )
            gsession = gs
            tv.controller = TerminalController(theme: juancodeGhosttyTheme)
            tv.configuration = TerminalSurfaceOptions(backend: .inMemory(gs))
            tv.delegate = self

            // Subscribe immediately (no replay available) and buffer until the surface
            // is live, so the shell's first prompt isn't lost. The pty callback is on a
            // background queue; surface writes hop to main.
            cancelOutput = pty.onOutput { [weak self] bytes in
                DispatchQueue.main.async {
                    guard let self else { return }
                    PerfMonitor.recordFeed(bytes.count)
                    if self.surfaceReady {
                        self.gsession?.receive(Data(bytes))
                    } else {
                        self.preSurfaceBuffer.append(contentsOf: bytes)
                    }
                }
            }
            let fire = onExit
            cancelExit = pty.onExit { _ in fire() }
        }

        func detach() {
            resizeWork?.cancel(); resizeWork = nil
            cancelOutput?(); cancelOutput = nil
            cancelExit?(); cancelExit = nil
            preSurfaceBuffer = []
            surfaceReady = false
            gsession = nil
        }

        // MARK: TerminalSurfaceLifecycleDelegate

        func terminalDidAttachSurface(_: TerminalSurface) {
            surfaceReady = true
            if !preSurfaceBuffer.isEmpty {
                gsession?.receive(Data(preSurfaceBuffer))
                preSurfaceBuffer = []
            }
        }

        func terminalDidDetachSurface() { surfaceReady = false }

        // MARK: TerminalSurfaceResizeDelegate

        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let last = self.lastSent, last.cols == columns, last.rows == rows { return }
                self.lastSent = (columns, rows)
                self.pty.resize(cols: columns, rows: rows)
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: work)
        }

        func terminalDidRingBell() { NSSound.beep() }
    }
}
