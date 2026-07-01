import SwiftUI
import AppKit
import GhosttyTerminal
import JuancodeCore
import JuancodeServices

/// SPIKE (juancode bd: replace SwiftTerm with GhosttyKit): a drop-in alternative
/// to `SwiftTermLive`, rendering the live pty with libghostty's GPU surface instead
/// of SwiftTerm's CoreGraphics one. Same public `View` interface so the call site
/// can A/B between them: Ghostty is the default, `JUANCODE_SWIFTTERM=1` opts back
/// to SwiftTerm for comparison (see `TerminalBackendChoice`).
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
    /// A change vs. the coordinator's last triggers a manual geometry recalc — see
    /// `AppModel.terminalResyncToken`.
    var resyncToken: Int = 0
    var autoFocusOnAppear: Bool = true
    /// Reports the real grid Ghostty measures for the current bounds (cols, rows).
    /// Lets a caller persist a surface-specific spawn size — e.g. the Oracle dock,
    /// which can't use the shared `TerminalGrid` (that's the main panes') and must
    /// respawn into a grid Ghostty actually rendered, not a hand-estimated one.
    var onGrid: ((Int, Int) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            GhosttyRepresentable(session: session, targetSize: proxy.size,
                                 remembersSize: remembersSize, focusToken: focusToken,
                                 resyncToken: resyncToken,
                                 autoFocusOnAppear: autoFocusOnAppear, onGrid: onGrid)
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
    var resyncToken: Int = 0
    var autoFocusOnAppear: Bool = true
    var onGrid: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(session: session, remembersSize: remembersSize) }

    func makeNSView(context: Context) -> GhosttyHostView {
        context.coordinator.onGrid = onGrid
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        context.coordinator.attach(to: tv)
        let host = GhosttyHostView(terminal: tv)
        host.focusOnAppear = autoFocusOnAppear
        host.onDrop = { [session] text in session.write(text) }
        return host
    }

    func updateNSView(_ nsView: GhosttyHostView, context: Context) {
        context.coordinator.onGrid = onGrid
        nsView.applySize(targetSize)
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.focusTerminal()
        }
        if resyncToken != context.coordinator.lastResyncToken {
            context.coordinator.lastResyncToken = resyncToken
            context.coordinator.forceResync()
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
        /// When we last pushed a grid to the pty, for the resize throttle below.
        private var lastResizeAt: DispatchTime?
        /// Max SIGWINCH cadence during a drag (~30fps). Small enough that the pty
        /// grid never trails the surface long enough to corrupt; large enough not to
        /// flood the agent's TUI with intermediate widths.
        private let resizeThrottle = DispatchTimeInterval.milliseconds(33)
        private let remembersSize: Bool
        var lastFocusToken = 0
        var lastResyncToken = 0
        /// Surface-specific grid sink (see `GhosttyLive.onGrid`).
        var onGrid: ((Int, Int) -> Void)?

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
            // `subscribeOutput` delivers the whole scrollback synchronously above, so
            // its `receive()` is already queued on main ahead of this block. Writing
            // bytes into a freshly-attached Ghostty surface doesn't itself schedule a
            // frame (only live wakeups do), so on a session switch the replayed history
            // sits un-drawn until a user event forces a tick — the "blank until you
            // select all the text" bug. Nudge one redraw right after the replay lands.
            DispatchQueue.main.async { [weak view] in view?.fitToSize() }
        }

        func terminalDidDetachSurface() {}

        func detach() {
            resizeWork?.cancel(); resizeWork = nil
            cancel?(); cancel = nil
            streaming = false
            gsession = nil
        }

        // MARK: TerminalSurfaceResizeDelegate

        /// Ghostty measured a new grid for the current bounds. Keep the pty in
        /// lockstep with the surface via a leading+trailing throttle (not a pure
        /// trailing debounce): Ghostty reflows its *display* grid on every layout
        /// tick, so during a sidebar/divider drag a trailing-only debounce never
        /// fires until you let go — for the whole drag the agent draws for the old
        /// grid into an already-reflowed surface, landing characters and SGR runs at
        /// the wrong cells (the corruption that only heals once the agent next idles
        /// and repaints). The leading edge pushes the first change immediately and
        /// the throttle coalesces the rest, with a guaranteed trailing send for the
        /// final settled size. Also remembered as the next spawn grid.
        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            resizeWork?.cancel()
            let now = DispatchTime.now()
            let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
            if earliest <= now {
                sendResize(cols: columns, rows: rows)
            } else {
                let work = DispatchWorkItem { [weak self] in self?.sendResize(cols: columns, rows: rows) }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: earliest, execute: work)
            }
        }

        private func sendResize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            lastResizeAt = .now()
            if remembersSize { TerminalGrid.remember(cols: cols, rows: rows) }
            if let last = lastSent, last.cols == cols, last.rows == rows { return }
            lastSent = (cols, rows)
            onGrid?(cols, rows)
            session.resize(cols: cols, rows: rows)
        }

        /// Manual "recalculate geometry": re-measure the surface, then force a genuine
        /// SIGWINCH (drop a row, then restore the real one a beat later) so the agent's
        /// TUI fully re-lays-out — even when the grid is unchanged and a plain same-size
        /// SIGWINCH would be a no-op. The escape hatch for a pane left mis-sized by a
        /// resize the automatic resync missed.
        func forceResync() {
            guard let tv = view else { return }
            tv.fitToSize()
            guard let grid = lastSent, grid.cols > 0, grid.rows > 0 else { return }
            let cols = grid.cols, rows = grid.rows
            lastSent = nil
            session.resize(cols: cols, rows: rows > 2 ? rows - 1 : rows + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                guard let self else { return }
                self.lastSent = (cols, rows)
                self.session.resize(cols: cols, rows: rows)
            }
        }

        // MARK: misc delegates

        func terminalDidRingBell() { NSSound.beep() }
    }
}

/// Ghostty counterpart of `SwiftTermEphemeral`: drives the libghostty surface from a
/// live `EphemeralPty` (a `$SHELL -i` for the bottom terminal panel / editor). On
/// attach the pty replays its scrollback so a re-created surface (e.g. after a session
/// switch) repaints history; but that replay — and the shell's first prompt — can
/// arrive before the surface is live, and `receive()` drops bytes while the surface is
/// nil. So we buffer pre-surface output and flush it on attach.
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
        private var lastResizeAt: DispatchTime?
        private let resizeThrottle = DispatchTimeInterval.milliseconds(33)
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

        /// Leading+trailing throttle so the pty stays in lockstep with the surface
        /// during a drag — see the main pane's `terminalDidResize` for why a pure
        /// trailing debounce corrupts the agent's render here.
        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            resizeWork?.cancel()
            let now = DispatchTime.now()
            let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
            if earliest <= now {
                send(cols: columns, rows: rows)
            } else {
                let work = DispatchWorkItem { [weak self] in self?.send(cols: columns, rows: rows) }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: earliest, execute: work)
            }
        }

        private func send(cols: Int, rows: Int) {
            lastResizeAt = .now()
            if let last = lastSent, last.cols == cols, last.rows == rows { return }
            lastSent = (cols, rows)
            pty.resize(cols: cols, rows: rows)
        }

        func terminalDidRingBell() { NSSound.beep() }
    }
}
