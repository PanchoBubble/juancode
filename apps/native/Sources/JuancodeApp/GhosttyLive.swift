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
        // Seed the token caches with the current values. The model's tokens count
        // requests made against EARLIER terminals; a fresh coordinator starting at 0
        // would treat any past ⌃L / ⌃⇧R as pending and replay it on first update —
        // stealing focus from the sidebar and firing a spurious SIGWINCH nudge into
        // a CLI that's still booting (mis-sized first paint on new sessions).
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.lastResyncToken = resyncToken
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
        /// The most recent grid the surface actually reported, recorded on EVERY
        /// resize before any throttle/dedup — the authoritative current size. Both
        /// the trailing throttled send and `forceResync` push *this* rather than a
        /// value captured earlier, so a stale/out-of-order intermediate resize can
        /// never be the last thing the pty hears (which stranded the CLI at a smaller
        /// grid than the surface — the black band below its output after a panel drag).
        private var lastSurfaceGrid: (cols: Int, rows: Int)?
        /// When we last pushed a grid to the pty, for the resize throttle below.
        private var lastResizeAt: DispatchTime?
        /// Max SIGWINCH cadence during a drag (~30fps). Small enough that the pty
        /// grid never trails the surface long enough to corrupt; large enough not to
        /// flood the agent's TUI with intermediate widths.
        private let resizeThrottle = DispatchTimeInterval.milliseconds(33)
        /// How long the surface must stay quiet after a layout-transition resize
        /// before we assert the settled grid (juancode-1th.2). Longer than any gap
        /// between the transition's own layout passes, shorter than feels laggy.
        private let transitionSettleDelay = DispatchTimeInterval.milliseconds(150)
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
            // This local view is going away — release the shared grid so a remote
            // viewer (web / phone) can take control of the pty size (juancode-1th.1).
            session.releaseGrid(owner: GridArbiter.localOwner)
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
        ///
        /// A panel open/close (or fullscreen) transition (`LayoutTransitionGate`)
        /// stays in lockstep too — juancode-1th.2 held every grid until the layout
        /// settled, but the surface has *already* reflowed by the time this fires,
        /// so on a streaming session every byte the CLI printed during the hold
        /// landed mis-wrapped in scrollback, beyond what any settle repaint can
        /// heal (juancode-qxb). What a transition still needs over a plain drag is
        /// the settle pass: once the layout stays quiet it makes sure the CLI
        /// repainted at the settled grid — see `settleAfterTransition`.
        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            lastSurfaceGrid = (columns, rows)
            resizeWork?.cancel()
            if LayoutTransitionGate.shared.active {
                let now = DispatchTime.now()
                let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
                if earliest <= now, flushSurfaceGrid() { sentDuringTransition = true }
                let work = DispatchWorkItem { [weak self] in self?.settleAfterTransition() }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + transitionSettleDelay, execute: work)
                return
            }
            let now = DispatchTime.now()
            let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
            if earliest <= now {
                flushSurfaceGrid()
            } else {
                let work = DispatchWorkItem { [weak self] in self?.flushSurfaceGrid() }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: earliest, execute: work)
            }
        }

        /// True when a resize actually reached the pty during the current layout
        /// transition — read (and reset) by `settleAfterTransition` to decide
        /// whether the CLI still needs a SIGWINCH at the settled grid.
        private var sentDuringTransition = false

        /// A layout transition finished (no new surface grid for
        /// `transitionSettleDelay`): make sure the CLI has repainted at the settled
        /// grid — with the *minimum* number of size changes, because every extra
        /// flap on a streaming session writes more mis-wrapped output into
        /// scrollback (juancode-qxb).
        /// - Settled grid already delivered mid-transition → the CLI repainted for
        ///   it; nothing to do.
        /// - Pty at a different grid → one plain send (a genuine size change).
        /// - Net-zero toggle with nothing delivered → the pty never heard a
        ///   SIGWINCH while the surface reflowed, so force one with the nudge.
        private func settleAfterTransition() {
            guard let g = lastSurfaceGrid else { return }
            if remembersSize { TerminalGrid.remember(cols: g.cols, rows: g.rows) }
            let delivered = sentDuringTransition
            sentDuringTransition = false
            if let last = lastSent, last.cols == g.cols, last.rows == g.rows {
                if delivered { return }
                lastResizeAt = .now()
                nudge(cols: g.cols, rows: g.rows)
            } else {
                sendResize(cols: g.cols, rows: g.rows)
            }
        }

        /// Push the *latest* surface grid to the pty. Reads `lastSurfaceGrid` at fire
        /// time rather than a value captured when the work item was scheduled, so the
        /// throttle's trailing send always asserts the final settled size — never a
        /// stale intermediate that would strand the CLI a few rows short (black band).
        /// Returns whether a resize actually reached the pty (not deduped/dropped).
        @discardableResult
        private func flushSurfaceGrid() -> Bool {
            guard let g = lastSurfaceGrid else { return false }
            return sendResize(cols: g.cols, rows: g.rows)
        }

        @discardableResult
        private func sendResize(cols: Int, rows: Int) -> Bool {
            guard cols > 0, rows > 0 else { return false }
            lastResizeAt = .now()
            if remembersSize { TerminalGrid.remember(cols: cols, rows: rows) }
            if let last = lastSent, last.cols == cols, last.rows == rows { return false }
            onGrid?(cols, rows)
            // Only cache the grid as sent once the pty actually adopts it. If the
            // session isn't running yet the resize is dropped; leaving `lastSent`
            // unset means the next identical measurement isn't deduped away. The
            // boot-time re-assert (slow CLI missing early SIGWINCHs) is now owned by
            // the server: `Session.reapplyGridWhenReady` re-applies the desired grid
            // once the TUI settles (juancode-1th.3), so no client-side retry needed.
            if session.resizeLocal(cols: cols, rows: rows) {
                lastSent = (cols, rows)
                return true
            } else {
                lastSent = nil
                return false
            }
        }

        /// Manual "recalculate geometry": re-measure the surface, then force a genuine
        /// SIGWINCH (drop a row, then restore the real one a beat later) so the agent's
        /// TUI fully re-lays-out — even when the grid is unchanged and a plain same-size
        /// SIGWINCH would be a no-op. The escape hatch for a pane left mis-sized by a
        /// resize the automatic resync missed. Works from `lastSurfaceGrid` (the true
        /// current size) rather than `lastSent`, so it can recover a pane even when the
        /// pty was left at a stale grid — the previous cache-only version just re-asserted
        /// that same stale size and appeared to do nothing.
        func forceResync() {
            guard let tv = view else { return }
            tv.fitToSize()
            guard let grid = lastSurfaceGrid ?? lastSent, grid.cols > 0, grid.rows > 0 else { return }
            nudge(cols: grid.cols, rows: grid.rows)
        }

        /// Force a genuine SIGWINCH at (cols, rows): drop a row, then restore the
        /// real one a beat later, so the TUI observes a size change and fully
        /// re-lays-out even when the grid is unchanged (a same-size TIOCSWINSZ
        /// delivers no signal). Shared by the manual resync and the automatic
        /// layout-transition settle. Like `sendResize`: if the pty isn't running yet
        /// the final size was dropped, so leave it un-cached rather than pretending it
        /// landed — the server's re-apply-on-settle covers the boot case (1th.3).
        private func nudge(cols: Int, rows: Int) {
            lastSent = nil
            session.resizeLocal(cols: cols, rows: rows > 2 ? rows - 1 : rows + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                guard let self else { return }
                if self.session.resizeLocal(cols: cols, rows: rows) {
                    self.lastSent = (cols, rows)
                } else {
                    self.lastSent = nil
                }
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
    /// True while the hosting panel is kept mounted but collapsed (keep-alive
    /// toggle, juancode-it1): freezes pty sizing so the collapse animation's
    /// shrinking grids never reach the shell, and occludes the surface so a hidden
    /// pane stops Metal-drawing on output.
    var hidden: Bool = false
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

    // SwiftUI calls this in the same transaction that flips `hidden` — before any
    // intermediate animation frame resizes the NSView — so the freeze lands first.
    func updateNSView(_ nsView: GhosttyHostView, context: Context) {
        context.coordinator.setHidden(hidden, host: nsView)
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
        private let pty: EphemeralPty
        private let onExit: @Sendable () -> Void
        private weak var view: TerminalView?
        private var gsession: InMemoryTerminalSession?
        private var cancelOutput: (() -> Void)?
        private var cancelExit: (() -> Void)?
        private var resizeWork: DispatchWorkItem?
        private var lastSent: (cols: Int, rows: Int)?
        /// Latest grid the surface reported (see the main pane's `lastSurfaceGrid`):
        /// the trailing throttled send reads this at fire time so it can't assert a
        /// stale intermediate size and leave the shell a few rows short.
        private var lastSurfaceGrid: (cols: Int, rows: Int)?
        private var lastResizeAt: DispatchTime?
        private let resizeThrottle = DispatchTimeInterval.milliseconds(33)
        /// Output that arrived before the surface existed; flushed on attach.
        private var preSurfaceBuffer: [UInt8] = []
        private var surfaceReady = false
        /// True while the hosting panel is collapsed (keep-alive toggle): surface
        /// resizes are recorded but never forwarded to the pty, so the collapse
        /// animation's shrinking grids can't rewrap the shell's scrollback.
        private var sizingFrozen = false

        init(pty: EphemeralPty, onExit: @escaping @Sendable () -> Void) {
            self.pty = pty
            self.onExit = onExit
        }

        /// Freeze/unfreeze pty sizing and surface rendering with the panel's
        /// visibility. On unhide, re-measure the restored bounds and flush the
        /// grid once (deduped by `send` if nothing actually changed).
        func setHidden(_ hidden: Bool, host: GhosttyHostView) {
            guard hidden != sizingFrozen else { return }
            sizingFrozen = hidden
            // Occlusion also stops render-tick scheduling — a hidden pane running
            // a build/tail stops Metal-drawing on every output burst.
            host.terminal.setSurfaceVisible(!hidden)
            if !hidden {
                host.terminal.fitToSize()
                flushSurfaceGrid()
            }
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
        /// trailing debounce corrupts the agent's render here, and why a layout
        /// transition (panel toggle) stays in lockstep too, with a settle pass
        /// that only forces a repaint when nothing was delivered (juancode-qxb).
        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            lastSurfaceGrid = (columns, rows)
            // Collapsed keep-alive panel: record the grid, never forward it. The
            // unhide path re-measures and flushes once.
            guard !sizingFrozen else { return }
            resizeWork?.cancel()
            if LayoutTransitionGate.shared.active {
                let now = DispatchTime.now()
                let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
                if earliest <= now, flushSurfaceGrid() { sentDuringTransition = true }
                let work = DispatchWorkItem { [weak self] in self?.settleAfterTransition() }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
                return
            }
            let now = DispatchTime.now()
            let earliest = lastResizeAt.map { $0 + resizeThrottle } ?? now
            if earliest <= now {
                flushSurfaceGrid()
            } else {
                let work = DispatchWorkItem { [weak self] in self?.flushSurfaceGrid() }
                resizeWork = work
                DispatchQueue.main.asyncAfter(deadline: earliest, execute: work)
            }
        }

        /// See the main pane's `sentDuringTransition`.
        private var sentDuringTransition = false

        /// Make sure the pty heard about the settled grid after a layout
        /// transition — minimum size changes, same tiering as the main pane
        /// (delivered → nothing; changed → plain send; net-zero → forced
        /// rows-1/rows SIGWINCH for a TUI running in this pane).
        private func settleAfterTransition() {
            guard let g = lastSurfaceGrid else { return }
            let delivered = sentDuringTransition
            sentDuringTransition = false
            if let last = lastSent, last.cols == g.cols, last.rows == g.rows {
                if delivered { return }
                lastResizeAt = .now()
                pty.resize(cols: g.cols, rows: g.rows > 2 ? g.rows - 1 : g.rows + 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                    self?.pty.resize(cols: g.cols, rows: g.rows)
                }
            } else {
                send(cols: g.cols, rows: g.rows)
            }
        }

        /// Push the latest surface grid to the pty (reads `lastSurfaceGrid` at fire
        /// time — see the main pane's `flushSurfaceGrid`). Returns whether a resize
        /// was actually sent (not deduped).
        @discardableResult
        private func flushSurfaceGrid() -> Bool {
            guard let g = lastSurfaceGrid else { return false }
            return send(cols: g.cols, rows: g.rows)
        }

        @discardableResult
        private func send(cols: Int, rows: Int) -> Bool {
            // Floor: the collapse animation can produce a tiny-but-valid grid on
            // its way to zero (the final 0-size sync is skipped upstream, so a
            // 2-row grid would stick and permanently rewrap the shell). The panel's
            // min height is 120pt ≈ 7 rows — no legitimate grid is ever this small.
            guard cols >= 10, rows >= 3 else { return false }
            lastResizeAt = .now()
            if let last = lastSent, last.cols == cols, last.rows == rows { return false }
            lastSent = (cols, rows)
            pty.resize(cols: cols, rows: rows)
            return true
        }

        func terminalDidRingBell() { NSSound.beep() }
    }
}
