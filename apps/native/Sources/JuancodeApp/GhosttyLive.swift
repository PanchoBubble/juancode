import SwiftUI
import AppKit
import Observation
import GhosttyTerminal
import JuancodeCore
import JuancodeServices

/// A drop-in alternative to `SwiftTermLive`, rendering the live pty with libghostty's
/// GPU surface instead of SwiftTerm's CoreGraphics one. Same public `View` interface, so
/// the call site can swap between them (see `TerminalBackend`).
///
/// The architecture is preserved: *we* own the pty (local `forkpty` / remote
/// `node-pty`); libghostty's `InMemoryTerminalSession` is a host-driven backend —
/// pty output is pushed in via `receive(_:)`, user input comes back via the `write`
/// callback, and grid changes arrive via the resize delegate → our SIGWINCH. No
/// process is spawned by Ghostty.

/// Which surface the live panes use: libghostty (the default) or SwiftTerm. A user-facing
/// Setting rather than the old `JUANCODE_GHOSTTY=1`-only switch, which is now just the
/// first-launch seed — set `JUANCODE_GHOSTTY=0` to start a fresh install on SwiftTerm.
///
/// Ghostty was forced off entirely for a while: on 1.2.x, `ghostty_surface_write_buffer`
/// wrote synchronously on the calling thread and deadlocked main on a Zig futex when
/// several panes attached at once (juancode-d89). Fixed upstream in libghostty-spm 1.3.0
/// (their PR #29 queues those writes per session), which is why this is a toggle again
/// and why `Package.swift` floors the dependency at 1.3.2. It's the default again as of
/// 2026-07-31: it's the surface this app is developed against, so a fresh clone should
/// get the fast GPU path without hunting through Settings first.
///
/// `@Observable` so flipping it re-runs the pane bodies that read it: visible panes swap
/// surface immediately, replaying their scrollback into the new one, exactly as they do
/// when a session is first opened. Same singleton pattern as `TerminalRenderer`.
@MainActor
@Observable
final class TerminalBackend {
    static let shared = TerminalBackend()

    private let defaultsKey = "juancode.terminal.useGhostty"

    private(set) var useGhostty: Bool

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            useGhostty = UserDefaults.standard.bool(forKey: defaultsKey)
        } else {
            // On by default; the env var is only an escape hatch for a first launch
            // (`JUANCODE_GHOSTTY=0`) before the Setting exists to be flipped.
            useGhostty = ProcessInfo.processInfo.environment["JUANCODE_GHOSTTY"] != "0"
        }
    }

    func setUseGhostty(_ on: Bool) {
        guard on != useGhostty else { return }
        useGhostty = on
        UserDefaults.standard.set(on, forKey: defaultsKey)
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
    /// True while this pane is kept MOUNTED but off-screen by the keep-alive pool
    /// (juancode-073): rendering is suspended (surface occluded), pty sizing and
    /// surface layout are frozen, and local grid ownership is released so a remote
    /// viewer can drive the pty. Flipping back to false runs the reveal recovery:
    /// unfreeze, one fit at the live bounds, re-claim + flush the grid (deduped),
    /// and a settled-frame repaint. Mirrors `GhosttyEphemeral.hidden`.
    var hidden: Bool = false
    /// How much of the pane is translated above the visible area by the caller's
    /// `.offset` (the bottom shell panel's height). Clicks in that band fall through
    /// to the views drawn under the pane — see `TerminalHitClip`.
    var topHitInset: CGFloat = 0
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
                                 autoFocusOnAppear: autoFocusOnAppear,
                                 hidden: hidden, topHitInset: topHitInset, onGrid: onGrid)
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
    /// True while this pane is kept mounted but off-screen (the keep-alive pool,
    /// juancode-073): the surface neither follows our bounds nor re-fits. A hidden
    /// surface must keep the exact grid the pty last heard — bytes the CLI streams
    /// while we're hidden are laid out for THAT grid, and letting the surface
    /// reflow underneath them would mis-wrap its state the same way raw-scrollback
    /// replay does. Reveal unfreezes and runs a single fit at the live bounds.
    var layoutFrozen = false
    /// Height of our own bounds that SwiftUI has translated above the visible area
    /// (the bottom shell panel's height). Clicks that land there belong to whatever
    /// is drawn under the pane — see `TerminalHitClip`.
    var topHitInset: CGFloat = 0
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        if TerminalHitClip.rejects(point: local, bounds: bounds, flipped: isFlipped,
                                   topInset: topHitInset) { return nil }
        return super.hitTest(point)
    }

    /// Pin the surface to our exact bounds, then let Ghostty re-measure. Unlike
    /// SwiftTerm we don't poke `needsDisplay` — the Metal surface schedules its own
    /// redraw from `fitToSize()`'s immediate tick.
    ///
    /// Frozen during a live window-edge drag (`inLiveResize`): every intermediate
    /// frame would reflow Ghostty's grid and push a SIGWINCH into a possibly
    /// streaming CLI, whose bytes for the old grid then land permanently
    /// mis-wrapped in scrollback — the "resize breaks the screen" bug. The surface
    /// keeps rendering at its pre-drag size (letterboxed against the moving edge)
    /// and adopts the final bounds exactly once in `viewDidEndLiveResize`. Orca
    /// (xterm.js) makes the same trade: no mid-drag resizes, one fit at settle.
    private func pin() {
        guard !inLiveResize, !layoutFrozen else { return }
        if terminal.frame != bounds { terminal.frame = bounds }
        terminal.fitToSize()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); pin() }
    override func layout() { super.layout(); pin() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); pin() }

    func applySize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        // Mid-drag SwiftUI sizes flow through here too; the final one is
        // re-applied from `viewDidEndLiveResize` via `pin()` (bounds are current).
        guard !inLiveResize, !layoutFrozen else { return }
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

/// Move a live Ghostty surface to the global terminal font-zoom level (juancode-fry),
/// returning the level now applied. Emits one 1pt binding action per step of delta
/// (mirroring libghostty's own pinch-zoom loop). If the surface isn't live yet the
/// first action returns false and we leave the applied level unchanged so the caller
/// retries on attach. After a real change we re-measure: the font resizes the grid for
/// the same pixel bounds, so `fitToSize()` fires the resize delegate and the existing
/// choreography (throttled SIGWINCH + resize-heal) re-lays-out the CLI — a streaming
/// agent is protected exactly as by a drag resize.
@MainActor
private func applyGhosttyZoom(view: TerminalView?, applied: Int) -> Int {
    let target = TerminalZoom.shared.level
    let steps = TerminalFontZoom.bindingSteps(from: applied, to: target)
    guard !steps.isEmpty else { return target }
    guard let tv = view else { return applied }
    for step in steps where !tv.performBindingAction(step) { return applied }
    tv.fitToSize()
    return target
}

private struct GhosttyRepresentable: NSViewRepresentable {
    let session: Session
    var targetSize: CGSize
    var remembersSize: Bool
    var focusToken: Int = 0
    var resyncToken: Int = 0
    var autoFocusOnAppear: Bool = true
    var hidden: Bool = false
    var topHitInset: CGFloat = 0
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
        nsView.topHitInset = topHitInset
        // Hide/reveal first: on hide the freeze must land before this pass's
        // `applySize` (which is a no-op while frozen); on reveal the unfreeze must
        // land before it, so the fit below already runs at the live bounds.
        let revealed = context.coordinator.setHidden(hidden, host: nsView)
        nsView.applySize(targetSize)
        if revealed {
            context.coordinator.completeReveal()
            if autoFocusOnAppear { nsView.focusTerminal() }
        }
        // Token bumps target the VISIBLE pane. Hidden keep-alive panes record them
        // (so nothing fires spuriously on reveal) but never act: a hidden pane
        // must not steal focus, and a resync nudge would fight whatever remote
        // viewer owns the grid while we're off-screen.
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            if !hidden { nsView.focusTerminal() }
        }
        if resyncToken != context.coordinator.lastResyncToken {
            context.coordinator.lastResyncToken = resyncToken
            if !hidden { context.coordinator.forceResync() }
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
    final class Coordinator: NSObject, TerminalSurfaceGridResizeDelegate, TerminalSurfaceBellDelegate,
                             TerminalSurfaceLifecycleDelegate {
        private let session: Session
        private weak var view: TerminalView?
        private var gsession: InMemoryTerminalSession?
        private var cancel: (() -> Void)?
        private var cancelGrid: (() -> Void)?
        private var streaming = false
        /// Batches pty output into one `receive()` per runloop turn (juancode-kdn).
        private var feedCoalescer: TerminalFeedCoalescer?
        /// Window-level keyDown monitor mapping Shift+Enter → `\`+CR (soft newline).
        private var shiftEnterMonitor: Any?
        private var resizeWork: DispatchWorkItem?
        private var lastSent: (cols: Int, rows: Int)?
        /// The most recent grid the surface actually reported, recorded on EVERY
        /// resize before any throttle/dedup — the authoritative current size. Both
        /// the trailing throttled send and `forceResync` push *this* rather than a
        /// value captured earlier, so a stale/out-of-order intermediate resize can
        /// never be the last thing the pty hears (which stranded the CLI at a smaller
        /// grid than the surface — the black band below its output after a panel drag).
        private var lastSurfaceGrid: (cols: Int, rows: Int)?
        /// Ghostty's cell metrics in surface pixels, captured off every resize
        /// report. Lets the pool-hidden adoption path (juancode-slz) size the
        /// frozen surface to exactly a remote owner's grid.
        private var cellPixels: (w: Int, h: Int)?
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
        /// How long `nudge`'s rows-1 → rows flap takes to complete, plus a beat — how
        /// long a repaint waits so it is encoded at the real grid, not the flap's.
        private let nudgeSettleMs = 140
        /// Post-resize heal (`TerminalResizeHeal`, shared with the SwiftTerm backend).
        /// A window-edge / divider drag pushes SIGWINCHes straight into a streaming
        /// CLI, so bytes it emitted for the pre-resize grid land mis-wrapped, and the
        /// drag path has no settle pass of its own (unlike a layout transition). Once
        /// the CLI's *output* stays quiet for the delay, `fireResizeHeal` repaints from
        /// the headless model and, if it was streaming, forces one genuine SIGWINCH.
        /// Keyed on output quiet, not layout quiet, because a drag can end while the
        /// CLI is still streaming.
        private lazy var heal = TerminalResizeHeal(quietMs: 250) { [weak self] action in
            // `onQuiet` fires on the main queue (see `TerminalResizeHeal`).
            MainActor.assumeIsolated { self?.fireResizeHeal(action) }
        }
        /// Observers that verify the grid when the app/window comes back to the
        /// front — a fullscreen / Space / display change while we were away can
        /// re-lay-out the window without the surface hearing a frame change.
        private var activeObservers: [Any] = []
        private let remembersSize: Bool
        /// True while this pane is pool-hidden (juancode-073): surface resizes are
        /// recorded but never forwarded to the pty, and wake/heal machinery stays
        /// quiet. Mirrors `GhosttyEphemeral.sizingFrozen`.
        private var sizingFrozen = false
        var lastFocusToken = 0
        var lastResyncToken = 0
        /// The font-zoom level currently applied to this surface (juancode-fry). A
        /// fresh surface renders at the backend default = level 0; `syncZoom` walks it
        /// to the global level on attach and on every zoom change.
        private var appliedZoomLevel = 0
        private var zoomObserver: Any?
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
            shiftEnterMonitor = installShiftEnterNewline(view: tv, session: session)
            // On each return to the front, verify the grid instead of nudging
            // blindly: `repairWakeDrift` reads the grid the pty actually applied
            // and fires a SIGWINCH only on true drift, so a clean pane's TUI never
            // repaints for nothing. (Coordinator is @MainActor ⇒ Sendable; the
            // observers fire on .main.) `didChangeScreen` / `didChangeScreenParameters`
            // cover monitor moves and resolution changes, which re-layout the window
            // without any activation event.
            for name in [NSApplication.didBecomeActiveNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeScreenNotification,
                         NSApplication.didChangeScreenParametersNotification] {
                activeObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.repairWakeDrift() }
                })
            }
            // While this pane is pool-hidden a remote viewer may take the grid
            // (juancode-073 released it); adopt its dims so the frozen surface
            // reflows in lockstep with the pty (juancode-slz). Fires from the
            // resize's own queue — hop to main for the surface.
            cancelGrid = session.onGridChange { [weak self] owner, cols, rows in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.adoptRemoteGridIfNeeded(owner: owner, cols: cols, rows: rows)
                    }
                }
            }
            // Follow the global terminal font-zoom level (juancode-fry): re-sync this
            // surface whenever ⌘+/⌘−/⌘0 change it. The initial sync happens on surface
            // attach (`terminalDidAttachSurface`), once the surface can take the action.
            zoomObserver = NotificationCenter.default.addObserver(
                forName: TerminalZoom.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncZoom() }
            }
            // NB: we deliberately do NOT subscribe to the pty yet. The surface is
            // created lazily once the view enters a window; `receive()` drops bytes
            // while the surface is nil, so an early scrollback replay would vanish.
            // Streaming starts from `terminalDidAttachSurface` instead.
        }

        // MARK: TerminalSurfaceLifecycleDelegate

        /// Surface is live — now it's safe to seed history + stream live output.
        func terminalDidAttachSurface(_: TerminalSurface) {
            guard !streaming else { return }
            streaming = true
            // Seed from the shared headless model, then stream live output into the
            // surface. The seed is a clean VT repaint synthesized from PARSED state
            // (`SessionTerminalModel.seedBytes()`), encoded at the model's grid — so
            // unlike a raw byte replay it can't land mis-wrapped when the pane's width
            // has moved since those bytes were written, and it carries no partial
            // escapes or stale alt-screen frames (juancode-a2h.2 / juancode-8llo).
            // The pty callback is on a background queue; surface writes must be on main.
            // Coalesce bursts into one receive() per runloop turn (juancode-kdn) so N
            // mounted, streaming sessions don't each reflow per chunk on main.
            let coalescer = TerminalFeedCoalescer { [weak self, weak gsession] bytes in
                gsession?.receive(Data(bytes))
                self?.heal.noteOutput()
            }
            feedCoalescer = coalescer
            if Config.useModelSeed {
                // Seed and subscribe atomically on the session workQueue: the clean
                // seed and the live stream partition with no gap, so a brand-new
                // session's boot burst can't be dropped between the two.
                cancel = session.subscribeFromModelSeed { bytes in coalescer.append(bytes) }
            } else {
                cancel = session.subscribeOutput(replay: true) { bytes in
                    coalescer.append(bytes)
                }
            }
            // Freshly-seeded history doesn't schedule a frame on its own, so on a
            // session switch it sits un-drawn until a user event forces a tick — the
            // "blank until you select all the text" bug. Nudge one redraw right after
            // the replay lands, and again after layout has certainly settled (the
            // immediate tick can race the surface's first real layout and be skipped).
            DispatchQueue.main.async { [weak view] in view?.fitToSize() }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak view] in
                view?.fitToSize()
            }
            // Seed the surface at the current global font-zoom level (juancode-fry).
            syncZoom()
        }

        func terminalDidDetachSurface() {}

        /// Walk this surface to the global font-zoom level (juancode-fry). No-op when
        /// already there or the surface isn't live yet (retried on attach).
        private func syncZoom() {
            appliedZoomLevel = applyGhosttyZoom(view: view, applied: appliedZoomLevel)
        }

        /// The app/window came back to the front. Repaint the surface, then repair
        /// the pty only when the grid it actually applied (TIOCGWINSZ readback)
        /// differs from the surface's — the verified version of the blind
        /// activation nudge, so an app-switch never makes a clean TUI re-lay-out.
        private func repairWakeDrift() {
            // Pool-hidden pane: nothing to repaint (occluded), and the pty may be
            // legitimately owned by a remote viewer at a different grid — a nudge
            // here would fight it. The reveal recovery re-asserts our grid.
            guard !sizingFrozen else { return }
            view?.fitToSize()
            guard let g = lastSurfaceGrid, g.cols > 0, g.rows > 0 else { return }
            guard let applied = session.appliedGrid() else { return }
            if applied.cols != g.cols || applied.rows != g.rows {
                nudge(cols: g.cols, rows: g.rows)
            }
        }

        /// Suspend/resume this pane with the keep-alive pool's visibility
        /// (juancode-073). Hiding freezes pty sizing + surface layout, occludes
        /// the surface (no Metal draws on output bursts), drops any pending
        /// resize/heal work, resigns focus, and releases the shared grid so a
        /// remote viewer (web / phone) can drive the pty size off-screen
        /// (juancode-1th.1). The output subscription stays live — Ghostty's
        /// terminal state keeps advancing, which is exactly what makes the reveal
        /// replay-free. Returns true on a hidden → visible transition; the caller
        /// re-applies the live bounds and then runs `completeReveal()`.
        func setHidden(_ hidden: Bool, host: GhosttyHostView) -> Bool {
            guard hidden != sizingFrozen else { return false }
            sizingFrozen = hidden
            host.layoutFrozen = hidden
            // SwiftUI's opacity is visual-only at the AppKit layer: the NSView
            // would still hit-test and its tracking areas still fire, so clicks,
            // wheel scrolls, and mouse reports over the terminal area could land
            // in an off-screen pane's pty. AppKit-hiding the host excludes it from
            // all event routing; the Ghostty surface survives (its lifecycle keys
            // off window membership, which isHidden doesn't change).
            host.isHidden = hidden
            // Occlusion also stops render-tick scheduling — a hidden pane running
            // a streaming agent stops Metal-drawing on every output burst.
            host.terminal.setSurfaceVisible(!hidden)
            guard hidden else { return true }
            // Stop feeding a surface we just occluded (juancode-o9h2). Occlusion parks
            // Ghostty's renderer/io loops, and a write that lands while they're parked
            // can wedge inside libghostty and never complete — it then holds the
            // in-memory backend's active-operation count forever, so tearing this
            // surface down later blocked the MAIN thread and froze the whole app. The
            // reveal re-seeds from the headless model instead of relying on the
            // surface having kept up (`resumeStreaming`), which is why this is safe to
            // cut mid-stream.
            suspendStreaming()
            resizeWork?.cancel(); resizeWork = nil
            heal.disarm()
            // A hidden pane must not keep swallowing keystrokes.
            if host.window?.firstResponder === host.terminal {
                host.window?.makeFirstResponder(nil)
            }
            session.releaseGrid(owner: GridArbiter.localOwner)
            return false
        }

        /// Reveal recovery, run after the host re-applied its live bounds: flush
        /// the surface grid to the pty unconditionally (`lastSent` cleared — a
        /// remote viewer may have driven the pty to its own size while we were
        /// hidden, which a dedup would wrongly skip), re-claiming local grid
        /// ownership in the same call. A genuine size change delivers the SIGWINCH
        /// that makes the CLI repaint at our grid; an unchanged size is a no-op at
        /// the kernel, so a clean reveal never disturbs the TUI. The delayed pass
        /// is the take-back repair (juancode-slz): a settled-frame repaint plus a
        /// drift-only pty verification — `repairWakeDrift` reads the grid the pty
        /// actually applied and nudges only on true drift, so a take-back from a
        /// same-sized remote never makes a clean TUI re-lay-out.
        /// Cut the pty → surface feed while this pane is occluded (juancode-o9h2).
        /// Ghostty's own terminal state stops advancing, which is what `resumeStreaming`
        /// repairs from the headless model on reveal.
        private func suspendStreaming() {
            guard streaming else { return }
            cancel?(); cancel = nil
            feedCoalescer = nil
            streaming = false
        }

        /// Resume feeding after a reveal. `subscribeFromModelSeed` (juancode-a2h.2)
        /// hands us one clean repaint built from the headless model's parsed rows and
        /// then every byte that lands after it — no gap and no overlap, because both
        /// happen in one block on the session's serial workQueue. That beats replaying
        /// raw pty bytes: the seed is well-formed by construction and is encoded at the
        /// model's current grid, so it can't land mis-wrapped the way a raw replay at a
        /// changed width does.
        private func resumeStreaming() {
            guard !streaming, let gsession else { return }
            streaming = true
            let coalescer = TerminalFeedCoalescer { [weak self, weak gsession] bytes in
                gsession?.receive(Data(bytes))
                self?.heal.noteOutput()
            }
            feedCoalescer = coalescer
            cancel = session.subscribeFromModelSeed { bytes in coalescer.append(bytes) }
        }

        func completeReveal() {
            // Re-seed before asserting the grid: the seed is encoded at the model's
            // current dimensions, and `flushSurfaceGrid` may change them.
            resumeStreaming()
            lastSent = nil
            flushSurfaceGrid()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self, !self.sizingFrozen else { return }
                self.repairWakeDrift()
            }
        }

        /// Adopt a remote grid owner's dimensions while this pane is pool-hidden
        /// (juancode-slz, Orca's mobile fit override): size the frozen surface
        /// frame to exactly (cols, rows) so Ghostty reflows in lockstep with the
        /// pty — bytes the CLI streams for the remote grid land correctly instead
        /// of mis-wrapping against our stale pane-bounds grid. The resize report
        /// this triggers is recorded but never forwarded (`sizingFrozen`), so no
        /// SIGWINCH fights the remote owner. Skipped when cell metrics aren't
        /// known yet — then the surface just stays at pane bounds and stays quiet
        /// (the acceptable fallback). Take-back restores the pane fit (reveal's
        /// `applySize`) and verifies via the drift-only repair above.
        private func adoptRemoteGridIfNeeded(owner: String?, cols: Int, rows: Int) {
            guard sizingFrozen, RemoteGridFit.isRemote(owner: owner) else { return }
            guard let cell = cellPixels, let tv = view else { return }
            let scale = tv.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            let size = RemoteGridFit.surfacePointSize(cols: cols, rows: rows,
                                                      cellWidthPx: cell.w, cellHeightPx: cell.h,
                                                      scale: scale)
            guard size.width > 0, size.height > 0 else { return }
            tv.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            tv.fitToSize()
        }

        func detach() {
            // This local view is going away — release the shared grid so a remote
            // viewer (web / phone) can take control of the pty size (juancode-1th.1).
            session.releaseGrid(owner: GridArbiter.localOwner)
            if let m = shiftEnterMonitor { NSEvent.removeMonitor(m); shiftEnterMonitor = nil }
            if let z = zoomObserver { NotificationCenter.default.removeObserver(z); zoomObserver = nil }
            activeObservers.forEach { NotificationCenter.default.removeObserver($0) }
            activeObservers.removeAll()
            resizeWork?.cancel(); resizeWork = nil
            heal.disarm()
            cancel?(); cancel = nil
            cancelGrid?(); cancelGrid = nil
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
        /// Metrics-bearing variant the surface coordinator prefers when the
        /// delegate conforms to `TerminalSurfaceGridResizeDelegate`: same grid
        /// flow as below, plus the cell pixel sizes the remote-grid adoption
        /// needs (juancode-slz).
        func terminalDidResize(_ size: TerminalGridMetrics) {
            if size.cellWidthPixels > 0, size.cellHeightPixels > 0 {
                cellPixels = (w: Int(size.cellWidthPixels), h: Int(size.cellHeightPixels))
            }
            terminalDidResize(columns: Int(size.columns), rows: Int(size.rows))
        }

        func terminalDidResize(columns: Int, rows: Int) {
            guard columns > 0, rows > 0 else { return }
            lastSurfaceGrid = (columns, rows)
            // Pool-hidden pane (juancode-073): record the grid, never forward it —
            // the host's layout freeze should prevent reflows entirely, but an
            // in-flight resize can still land here after the hide. The reveal
            // recovery re-measures and flushes once.
            guard !sizingFrozen else { return }
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
            // A plain drag has no layout-transition settle pass; arm the output-quiet
            // heal so a resize that lands mid-stream gets one clean repaint (and, if the
            // CLI was streaming, one re-lay-out) once it stops emitting — see `heal`.
            heal.arm()
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

        /// The CLI's output has settled after a resize. Repaint the surface from the
        /// headless model — the model parsed every byte at the pty's own grid, so its
        /// rows are the frame the CLI actually drew, where the surface may be holding
        /// bytes it reflowed a layout tick early. If the CLI was streaming through the
        /// resize, also force one genuine SIGWINCH so it re-lays-out at the settled
        /// grid. The policy disarms *before* we act, so the redraw bytes this provokes
        /// don't re-arm the heal into a loop.
        private func fireResizeHeal(_ action: ResizeHealAction) {
            guard let g = lastSurfaceGrid, g.cols > 0, g.rows > 0 else { return }
            if action.sigwinch {
                // The CLI streamed through the resize: make it re-lay-out, then repaint
                // once the flap has landed — the nudge walks the grid through `rows-1`,
                // and a repaint encoded at that transient size would be skipped by the
                // grid check for nothing.
                nudge(cols: g.cols, rows: g.rows)
                scheduleRepaint(matching: g, afterMs: nudgeSettleMs)
            } else if action.repaint {
                // Idle resize: the CLI has nothing to redraw, so no SIGWINCH — but a
                // stale frame can still be on screen. The model's rows are the truth.
                repaintFromModel(matching: g)
            }
        }

        /// Push a clean repaint of the model's current screen into the surface, in
        /// stream order (juancode-8llo). Routed through the same coalescer as live
        /// output so it can never land between the halves of a chunk, and skipped for a
        /// pool-hidden pane — that surface is occluded and re-seeds on reveal anyway.
        /// `matching` is the surface's grid: the model is only painted when it agrees
        /// (checked next to the encode, on the session workQueue).
        private func repaintFromModel(matching grid: (cols: Int, rows: Int)) {
            guard Config.useModelSeed, streaming, !sizingFrozen else { return }
            guard let coalescer = feedCoalescer else { return }
            session.repaintFromModel(matching: grid) { bytes in coalescer.append(bytes) }
        }

        /// Repaint after the grid work has certainly landed — longer than `nudge`'s
        /// flap so the model is back at the real grid by the time we encode.
        private func scheduleRepaint(matching grid: (cols: Int, rows: Int), afterMs: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterMs)) { [weak self] in
                self?.repaintFromModel(matching: grid)
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
            // Always flush one client repaint at settle, in every branch. Bytes the
            // CLI printed while the panel animated can arrive without scheduling a
            // frame (output wakeups are gated while the surface isn't renderable),
            // leaving a stale partial frame on screen that only a user event — the
            // "select all the text" heal — would flush. `fitToSize` ends in an
            // unconditional immediate tick and never touches the pty, so it's safe
            // even when the settled grid was already delivered mid-transition.
            view?.fitToSize()
            let delivered = sentDuringTransition
            sentDuringTransition = false
            // Whichever branch runs, finish by repainting from the headless model
            // (juancode-8llo). A transition reflows the surface *before* the pty hears
            // the new grid, so whatever the CLI printed mid-animation is laid out at
            // the wrong width — the interleaved stale rows a rail/drawer toggle leaves
            // behind. The model's grid only ever moves inside `Session.resize`, so it
            // parsed those same bytes at the pty's own width: its rows are the frame the
            // CLI actually drew. A SIGWINCH makes the CLI redraw its own regions, but
            // not rows it believes are already correct — this is what clears those.
            if let last = lastSent, last.cols == g.cols, last.rows == g.rows {
                if delivered {
                    // Settled grid already delivered mid-transition: no size change is
                    // coming, so the model is at `g` now and can be painted right away.
                    repaintFromModel(matching: g)
                    return
                }
                lastResizeAt = .now()
                nudge(cols: g.cols, rows: g.rows)
            } else {
                sendResize(cols: g.cols, rows: g.rows)
            }
            scheduleRepaint(matching: g, afterMs: nudgeSettleMs)
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
        /// Global font-zoom level applied to this shell surface (juancode-fry).
        private var appliedZoomLevel = 0
        private var zoomObserver: Any?

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
            // Follow the global terminal font-zoom level (juancode-fry).
            zoomObserver = NotificationCenter.default.addObserver(
                forName: TerminalZoom.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncZoom() }
            }
        }

        func detach() {
            resizeWork?.cancel(); resizeWork = nil
            cancelOutput?(); cancelOutput = nil
            cancelExit?(); cancelExit = nil
            if let z = zoomObserver { NotificationCenter.default.removeObserver(z); zoomObserver = nil }
            preSurfaceBuffer = []
            surfaceReady = false
            gsession = nil
        }

        /// Walk this shell surface to the global font-zoom level (juancode-fry).
        private func syncZoom() {
            appliedZoomLevel = applyGhosttyZoom(view: view, applied: appliedZoomLevel)
        }

        // MARK: TerminalSurfaceLifecycleDelegate

        func terminalDidAttachSurface(_: TerminalSurface) {
            surfaceReady = true
            if !preSurfaceBuffer.isEmpty {
                gsession?.receive(Data(preSurfaceBuffer))
                preSurfaceBuffer = []
            }
            // Open at the current global zoom level (juancode-fry).
            syncZoom()
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
