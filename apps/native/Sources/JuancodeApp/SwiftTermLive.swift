import SwiftUI
import AppKit
import SwiftTerm
import JuancodeCore

/// SwiftUI identity for a live terminal view: its `Session` object plus a manual
/// `refresh` counter. A change to *either* recreates the view — the session swap
/// (a permissions flip mints a new `Session` behind the same pty) and the Refresh
/// button (bumps the counter) both force a fresh subscribe-with-replay repaint.
struct TerminalIdentity: Hashable {
    let session: ObjectIdentifier
    let refresh: Int
    init(session: Session, refresh: Int) {
        self.session = ObjectIdentifier(session)
        self.refresh = refresh
    }
}

/// Makes the mouse wheel work inside full-screen TUIs.
///
/// SwiftTerm's stock `scrollWheel` only ever scrolls the *local* scrollback
/// buffer and ignores mouse reporting — and it's not `open`, so we can't override
/// it. The claude/codex agents run their UI on the alternate screen with mouse
/// tracking enabled, where there is no local scrollback, so the wheel looks dead.
/// We intercept scroll events with a local monitor: when the program under the
/// pointer has mouse reporting on, forward the wheel as xterm wheel-button events
/// so the app scrolls its own transcript and swallow the event; otherwise let it
/// through to SwiftTerm's native scrollback behaviour.
func installWheelForwarding(on tv: TerminalView) -> Any? {
    // All view access lives in this main-actor-isolated handler (so it's implicitly
    // Sendable). Returns true when it consumed the wheel. Args are plain scalars so
    // nothing non-Sendable crosses into the nonisolated monitor closure below.
    let handle: @MainActor (Double, CGPoint) -> Bool = { [weak tv] deltaY, location in
        // Gate on the program's requested mouseMode only — NOT on the view's
        // `allowMouseReporting`, which we deliberately disable (see `attach`) to stop
        // hover/motion from being typed into the pty. Our wheel events go through
        // `terminal.sendEvent` directly, which is independent of that view flag.
        guard let tv, let terminal = tv.terminal,
              terminal.mouseMode != .off,
              // Only the terminal actually under the pointer should consume it.
              tv.bounds.contains(tv.convert(location, from: nil)) else { return false }
        let ticks = max(1, min(6, Int(abs(deltaY))))
        // xterm encodes wheel-up as button 64 and wheel-down as 65. Position is
        // irrelevant for these apps' full-screen scroll regions, so report (0,0).
        let button = deltaY > 0 ? 64 : 65
        for _ in 0..<ticks { terminal.sendEvent(buttonFlags: button, x: 0, y: 0) }
        return true
    }
    // The monitor always fires on the main thread, so assuming isolation is safe.
    return NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        // Read the Sendable scalars out here so the non-Sendable event doesn't
        // cross into the main-actor handler.
        let deltaY = event.deltaY
        let location = event.locationInWindow
        guard deltaY != 0 else { return event }
        let consumed = MainActor.assumeIsolated { handle(deltaY, location) }
        return consumed ? nil : event
    }
}

/// Vim-style sidebar navigation + ⌃H/⌃L pane focus (juancode-vgm).
///
/// The live terminal makes itself first responder and SwiftTerm swallows every
/// keystroke, so a SwiftUI `.onKeyPress`/`.keyboardShortcut` can't see these keys
/// while a session is focused. A window-scoped local `keyDown` monitor sits *ahead*
/// of the responder chain — returning `nil` cancels dispatch, so we can act on a key
/// before the terminal ever sees it. We derive the active pane from the live first
/// responder (robust to mouse clicks) rather than tracking it ourselves:
///
/// - **In the terminal:** only ⌃H is intercepted (→ focus sidebar). Everything else,
///   including ⌃L (clear screen), passes straight through, so normal typing is intact.
/// - **In the sidebar:** j/k (and ↓/↑) move the selection, g/G jump to first/last,
///   Enter/l/⌃L open the session (focus the terminal). Modified keys pass through so
///   app shortcuts (⌘N, ⌃Space, …) still fire; plain keys are swallowed so they don't
///   leak into the pty behind the list.
///
/// Scoped to our own key window (and only when no sheet is attached / no text field is
/// editing) so it never hijacks dialogs or the filter field.
@MainActor
func installPaneNavigation(model: AppModel, oracle: OracleModel, shortcuts: Shortcuts, host: NSView) -> Any? {
    // App-level shortcuts (⌘N, ⌃Space, …) while a terminal holds focus: the terminal
    // surface (Ghostty/SwiftTerm) consumes ⌘-key events for the pty before the main
    // menu's key equivalents ever fire, so the menu commands silently do nothing. We
    // sit ahead of the chain here — match the event against the live bindings and run
    // the action directly, consuming the event so it doesn't also leak into the pty.
    // Only when a terminal is first responder; elsewhere the menu key equivalents work.
    let routeAppShortcut: @MainActor (NSEvent) -> Bool = { [weak host] event in
        guard let window = host?.window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder is JuancodeTerminalResponder
        else { return false }
        if let action = shortcuts.action(matching: event) {
            performShortcut(action, model: model, oracle: oracle)
            return true
        }
        // ⌃N mirrors ⌘N while the Oracle dock is open: start a new Oracle session.
        // Only intercepted with the dock up — otherwise ⌃N stays the pty's (readline
        // next-history / cursor-down).
        if oracle.expanded,
           event.modifierFlags.intersection([.command, .shift, .control, .option]) == .control,
           (event.charactersIgnoringModifiers ?? "").lowercased() == "n" {
            oracle.newOracle()
            return true
        }
        return false
    }
    let handle: @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool = { [weak host] keyCode, mods in
        guard let window = host?.window, window.isKeyWindow, window.attachedSheet == nil
        else { return false }
        let fr = window.firstResponder
        let ctrl = mods.contains(.control)

        // Terminal pane: only ⌃H escapes to the sidebar; all else (incl. ⌃L) is the pty's.
        // Matches both SwiftTerm and Ghostty surfaces via the shared marker.
        if fr is JuancodeTerminalResponder {
            // Back in the pty by any route (incl. a mouse click) — clear the nav guard so
            // a later row click auto-focuses its terminal again. Guarded to avoid churn.
            if model.suppressTerminalAutoFocus { model.suppressTerminalAutoFocus = false }
            guard ctrl, keyCode == 4 else { return false } // ⌃H
            window.makeFirstResponder(nil)
            model.focusSidebar()
            return true
        }
        // Editing the filter / rename field — leave typing untouched.
        if fr is NSTextView { return false }

        // Sidebar pane.
        if ctrl, keyCode == 37 { model.focusTerminal(); return true } // ⌃L → terminal
        // Let modified keys through so app-level shortcuts keep working.
        if !mods.intersection([.command, .control, .option]).isEmpty { return false }
        switch keyCode {
        case 38, 125: model.moveSelection(by: 1); return true   // j / ↓
        case 40, 126: model.moveSelection(by: -1); return true  // k / ↑
        case 36, 76, 37: model.focusTerminal(); return true     // ⏎ / enter / l → open
        case 5: mods.contains(.shift) ? model.selectLast() : model.selectFirst(); return true // g / G
        case 53: return false                                   // Esc passes through
        default: return true                                    // swallow; don't leak to the pty
        }
    }
    return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if MainActor.assumeIsolated({ routeAppShortcut(event) }) { return nil }
        let keyCode = event.keyCode
        let mods = event.modifierFlags
        let consumed = MainActor.assumeIsolated { handle(keyCode, mods) }
        return consumed ? nil : event
    }
}

/// Hosts a SwiftTerm `TerminalView`, owning the two things our thin SwiftUI
/// wrappers otherwise leave to chance:
///
/// 1. **Resize.** SwiftUI sizes the view it gets from `makeNSView`, but a bare
///    `TerminalView` doesn't reliably pick that up. We pin the terminal to our
///    bounds on every `layout()`, so the grid (and the pty via SIGWINCH) always
///    tracks the real size — and nudge a redraw so the new frame paints.
/// 2. **Drag-and-drop.** SwiftTerm registers no dragged types, so dropping a file
///    did nothing. We accept file URLs and hand their (shell-quoted) paths to
///    `onDrop`, which writes them into the session/pty as if typed.
final class TerminalHostView: NSView {
    let terminal: TerminalView
    /// Called with shell-quoted, space-joined dropped file paths. Nil ⇒ no drops.
    var onDrop: ((String) -> Void)?
    /// Called with the grid SwiftTerm computed for our real bounds (cols, rows),
    /// every time we re-pin. Drives the pty SIGWINCH from the *actual* laid-out size
    /// rather than relying on SwiftTerm's change-only delegate — see `pinTerminal`.
    var onGrid: ((Int, Int) -> Void)?
    /// When true, grab keyboard focus the first time we land in a window, so opening
    /// a session puts the cursor in the terminal without a manual click. Set only for
    /// the live terminal (the read-only replay view leaves it off).
    var focusOnAppear = false
    private var didAutoFocus = false

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        // Single source of truth for the terminal's size: we pin its frame to our
        // bounds ourselves. The autoresizing mask is deliberately OFF — letting
        // AppKit auto-resize the subview *and* setting the frame manually means the
        // terminal can be sized twice with different values during one drag, which
        // recomputes the grid mid-stream and garbles the agent's TUI.
        terminal.autoresizingMask = []
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.frame = bounds
        addSubview(terminal)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // Focus the terminal the first time it joins a window so a freshly-opened session
    // is ready to type into. Deferred to the next run-loop tick: at `viewDidMoveToWindow`
    // time the window may not yet be key, so `makeFirstResponder` could be ignored.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, !didAutoFocus, window != nil else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    /// Pin the terminal to our exact bounds. SwiftTerm's own `setFrameSize`
    /// recomputes the grid (cols/rows) and fires `sizeChanged` from here, so this is
    /// the one place size flows from. Always nudge a repaint so the CoreGraphics
    /// renderer fills any newly-exposed area after a grow (no black bands).
    private func pinTerminal() {
        if terminal.frame != bounds {
            terminal.frame = bounds
        }
        terminal.needsDisplay = true
        // Report the grid SwiftTerm now has for these bounds. Setting the frame above
        // runs SwiftTerm's `setFrameSize` → `processSizeChange` synchronously, so the
        // model's cols/rows are current here. This fires on every layout (not just
        // when the grid *changes*), so a stale pty gets re-synced even if SwiftTerm's
        // own delegate stayed quiet.
        if let t = terminal.terminal, t.cols > 0, t.rows > 0 {
            onGrid?(t.cols, t.rows)
        }
    }

    // `setFrameSize` is the reliable hook — SwiftUI resizing the host (window split,
    // panel drag, or the Oracle dock grip) always routes through it; `layout()`
    // isn't guaranteed to fire for a frame-based NSView, so we cover both.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pinTerminal()
    }

    override func layout() {
        super.layout()
        pinTerminal()
    }

    // After a live drag (window edge / split divider) settles, guarantee the grid +
    // pty land on the *final* size — intermediate frames are coalesced, so the last
    // one could otherwise be the value the CLI is left rendering at.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pinTerminal()
    }

    /// Make the terminal first responder on demand (⌃Space focus request). Deferred
    /// a tick so it works even if the window isn't key yet at call time.
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    /// Apply the authoritative SwiftUI size (from the wrapping GeometryReader, via
    /// `updateNSView`). Setting the terminal's frame runs SwiftTerm's `setFrameSize`
    /// → `processSizeChange` synchronously, recomputing the grid and firing
    /// `sizeChanged`; we also report the grid directly so the pty SIGWINCH is sent
    /// even if the grid value didn't change but the pty was stale. This is what makes
    /// a freshly-opened session size correctly instead of staying at 80x24.
    func applySize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let f = NSRect(origin: .zero, size: size)
        if terminal.frame != f {
            terminal.frame = f
        }
        terminal.needsDisplay = true
        if let t = terminal.terminal, t.cols > 0, t.rows > 0 { onGrid?(t.cols, t.rows) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && !droppedPaths(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        guard let onDrop, !paths.isEmpty else { return false }
        // Trailing space so the user can keep typing after the inserted path(s).
        onDrop(paths.map(shellQuote).joined(separator: " ") + " ")
        return true
    }

    private func droppedPaths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.map(\.path)
    }
}

extension TerminalView: JuancodeTerminalResponder {}

/// Remembers the last on-screen terminal grid (cols×rows) so a newly-spawned CLI
/// can boot already matching the visible terminal. Persisted in UserDefaults; read
/// by `AppModel` when spawning/resuming a session. Falls back to a roomy default.
enum TerminalGrid {
    private static let key = "juancode.lastTerminalGrid"
    static func remember(cols: Int, rows: Int) {
        guard cols >= 20, rows >= 10 else { return }
        UserDefaults.standard.set("\(cols),\(rows)", forKey: key)
    }
    static var spawn: (cols: Int, rows: Int) {
        let parts = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").compactMap { Int($0) }
        if parts.count == 2, parts[0] >= 20, parts[1] >= 10 { return (parts[0], parts[1]) }
        return (120, 40)
    }
}

/// Shell-quote a path so a dropped file with spaces/specials is inserted as one
/// argument. Bare paths (only safe chars) are left as-is.
private func shellQuote(_ path: String) -> String {
    if path.range(of: "[^A-Za-z0-9_./-]", options: .regularExpression) == nil { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, driven by a live `Session`.
///
/// The size is driven from SwiftUI's authoritative geometry (a `GeometryReader`)
/// rather than from NSView layout callbacks: relying on `setFrameSize`/`layout`
/// timing left freshly-opened sessions stuck at the spawn-time 80x24 (the pty was
/// never resized) while the grid raced the new-session sheet dismiss. Feeding the
/// exact laid-out size in as a value makes `updateNSView` fire with it deterministically.
struct SwiftTermLive: View {
    let session: Session
    /// Whether this terminal's size should be remembered as the spawn size for the
    /// next session. True for the main session view; false for the Oracle dock (its
    /// narrower grid must not shrink the size new main-window sessions boot at).
    var remembersSize: Bool = true
    /// Bump to request keyboard focus (⌃Space). Each change makes the terminal first
    /// responder; the initial value is ignored (the view auto-focuses on appear).
    var focusToken: Int = 0
    /// Bump to manually re-measure + force a SIGWINCH (see `AppModel.terminalResyncToken`).
    var resyncToken: Int = 0
    /// Whether the terminal grabs keyboard focus the first time it appears. False
    /// while the sidebar is being keyboard-navigated, so opening rows with j/k doesn't
    /// yank focus into the pty on every move (juancode-vgm).
    var autoFocusOnAppear: Bool = true

    var body: some View {
        GeometryReader { proxy in
            SwiftTermRepresentable(session: session, targetSize: proxy.size,
                                   remembersSize: remembersSize, focusToken: focusToken,
                                   resyncToken: resyncToken,
                                   autoFocusOnAppear: autoFocusOnAppear)
        }
    }
}

/// The in-process subscriber to the session's pty fan-out (replaying scrollback on
/// attach), routing keystrokes/resize straight back to the pty — no WebSocket hop.
/// Mirrors what the React `Terminal` component does over WS.
private struct SwiftTermRepresentable: NSViewRepresentable {
    let session: Session
    /// The exact size SwiftUI laid this view out at (from the wrapping GeometryReader).
    var targetSize: CGSize
    var remembersSize: Bool
    /// Latest focus-request token; a change vs. the coordinator's last makes the
    /// terminal grab focus (⌃Space). See `SwiftTermLive.focusToken`.
    var focusToken: Int = 0
    /// Latest resync-request token; a change vs. the coordinator's last re-measures
    /// the grid and forces a SIGWINCH. See `SwiftTermLive.resyncToken`.
    var resyncToken: Int = 0
    var autoFocusOnAppear: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(session: session, remembersSize: remembersSize) }

    func makeNSView(context: Context) -> TerminalHostView {
        // Seed the token caches with the current values — a fresh coordinator at 0
        // would replay a past ⌃L / ⌃⇧R on first update (focus steal + spurious
        // resync nudge on every newly-opened terminal). See GhosttyRepresentable.
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.lastResyncToken = resyncToken
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        tv.terminalDelegate = context.coordinator
        // Stop SwiftTerm from auto-forwarding mouse motion/clicks to the pty. When a
        // TUI enables motion tracking (DECSET 1002/1003) the view encodes every
        // mouse-move over the terminal as an escape sequence; if the program doesn't
        // consume them cleanly they land as junk in the input line. Wheel scrolling
        // stays alive via `installWheelForwarding`, which sends button events directly.
        tv.allowMouseReporting = false
        context.coordinator.attach(to: tv)
        let host = TerminalHostView(terminal: tv)
        host.focusOnAppear = autoFocusOnAppear
        host.onDrop = { [session] text in session.write(text) }
        host.onGrid = { cols, rows in context.coordinator.gridChanged(cols: cols, rows: rows) }
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // Apply the authoritative SwiftUI size to the terminal. This fires whenever
        // the laid-out size changes (open, panel toggle, window/divider drag), so the
        // grid + pty always track the real on-screen size.
        nsView.applySize(targetSize)
        // Honor a focus request (⌃Space): only when the token actually changed, so
        // routine size-driven updates don't keep stealing focus.
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.focusTerminal()
        }
        if resyncToken != context.coordinator.lastResyncToken {
            context.coordinator.lastResyncToken = resyncToken
            context.coordinator.forceResync()
        }
    }

    // Without this, SwiftUI sizes the bridged view to its intrinsic size and it
    // never grows. Returning the proposed size makes it fill the space it's given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }

    static func dismantleNSView(_ nsView: TerminalHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: Session
        private weak var view: TerminalView?
        private var cancel: (() -> Void)?
        private var wheelMonitor: Any?
        private var resizeWork: DispatchWorkItem?
        /// Last (cols,rows) we pushed to the pty, so we never send a redundant
        /// SIGWINCH (which makes the agent's TUI repaint for no reason).
        private var lastSent: (cols: Int, rows: Int)?
        /// Latest grid size SwiftTerm computed (from `sizeChanged`). Cached as plain
        /// ints so a reactivation nudge can re-send it without touching the main-actor view.
        private var lastGrid: (cols: Int, rows: Int)?
        /// Observers that re-assert the grid when the app/window comes back to the front
        /// (activation / de-miniaturize) — a fullscreen / display / Space change can
        /// re-lay-out the window without routing a frame change through `sizeChanged`.
        private var activeObservers: [Any] = []
        /// Whether to record this terminal's size as the next spawn size (see SwiftTermLive).
        private let remembersSize: Bool
        /// Last focus-request token honored, so a focus only fires when it changes.
        var lastFocusToken = 0
        /// Last resync-request token honored, so a recalc only fires when it changes.
        var lastResyncToken = 0

        init(session: Session, remembersSize: Bool) {
            self.session = session
            self.remembersSize = remembersSize
        }

        func attach(to tv: TerminalView) {
            view = tv
            wheelMonitor = installWheelForwarding(on: tv)
            // Replay scrollback, then stream live output. Feed must happen on the
            // main thread (AppKit); the pty callback arrives on a background queue.
            cancel = session.subscribeOutput(replay: true) { [weak tv] bytes in
                DispatchQueue.main.async {
                    PerfMonitor.recordFeed(bytes.count)
                    tv?.feed(byteArray: bytes[...])
                }
            }
            let session = self.session
            // A fullscreen / display / Space change, or coming back from a minimize or
            // app-switch, can re-lay-out the window without routing a frame change
            // through `sizeChanged` — leaving the pty at a stale (smaller) grid, so the
            // agent paints into a sub-rectangle with black margins until you reactivate.
            // Re-assert the real grid (nudged, so it actually re-lays-out) on each such
            // event. Capture only the weak view + Sendable session — never `self` — so
            // these `@Sendable` notification closures stay race-free.
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didDeminiaturizeNotification] {
                activeObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak tv] _ in
                    MainActor.assumeIsolated { Self.nudgeResize(tv, session) }
                })
            }
            // The boot-time resync (slow CLI missing early SIGWINCHs) is now owned by
            // the server: `Session.reapplyGridWhenReady` re-asserts the desired grid
            // once the TUI settles (juancode-1th.3). This view only handles later
            // window relayouts (the reactivation nudge above) and manual `forceResync`.
        }

        /// Nudge the pty to the view's live grid: send `rows-1` then the real `rows` a
        /// beat later, so the agent observes a genuine size change and fully re-lays-out.
        /// A plain same-size SIGWINCH can be a no-op — which is exactly why a drifted
        /// session only fills the available space after a reactivate. Static with
        /// Sendable-only captures so it's safe to call from `@Sendable` closures.
        @MainActor private static func nudgeResize(_ tv: TerminalView?, _ session: Session) {
            guard let t = tv?.terminal, t.cols > 0, t.rows > 0 else { return }
            let cols = t.cols, rows = t.rows
            session.resizeLocal(cols: cols, rows: rows > 2 ? rows - 1 : rows + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
                session.resizeLocal(cols: cols, rows: rows)
            }
        }

        /// Manual "recalculate geometry": re-measure the view's grid and force a genuine
        /// SIGWINCH so the agent's TUI fully re-lays-out. The escape hatch for a pane
        /// left mis-sized by a resize the automatic resync missed. `updateNSView` has
        /// already applied the current bounds by the time this runs.
        @MainActor func forceResync() {
            lastSent = nil
            Self.nudgeResize(view, session)
        }

        /// The CLI is spawned at a default 80x24. Once SwiftTerm has measured its
        /// cell size and the view has its real bounds, the grid SwiftTerm renders can
        /// be much larger than what the CLI thinks it has — leaving a black band
        /// below the agent's output (the bug: terminal "doesn't resize"). A single
        /// early SIGWINCH can also land before the TUI installs its handler. So we
        /// resync the pty to the live grid a few times across the boot window;
        /// `sendResize` dedups so steady state sends nothing.
        /// The host computed a grid for its real bounds. Cache it and push a
        /// debounced SIGWINCH so the pty tracks the actual on-screen size.
        func gridChanged(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            scheduleResize(cols: cols, rows: rows)
        }

        /// True when a grid change in the pending debounce window arrived during a
        /// panel open/close transition (`LayoutTransitionGate`) — the flush must
        /// then force a full re-layout (nudge) rather than a plain resize: a
        /// net-zero toggle settles at the grid the pty already has, where a plain
        /// send dedups to nothing, no SIGWINCH fires, and the frames rendered
        /// mid-transition stay garbled until a manual resync (juancode-1th.2).
        private var settleAfterTransition = false

        /// Trailing-debounced resize: cache the latest grid and (re)arm the flush.
        /// The debounce already suppresses intermediate grids; the transition flag
        /// upgrades the eventual flush to a forced re-layout.
        private func scheduleResize(cols: Int, rows: Int) {
            lastGrid = (cols, rows)
            if LayoutTransitionGate.shared.active { settleAfterTransition = true }
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushResize() }
            resizeWork = work
            let delay: DispatchTimeInterval = settleAfterTransition ? .milliseconds(150) : .milliseconds(90)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// Push the latest grid to the pty. After a layout transition, do it as a
        /// genuine SIGWINCH (see `settleAfterTransition`) so the TUI fully
        /// re-lays-out at the settled size.
        private func flushResize() {
            guard let g = lastGrid else { return }
            if settleAfterTransition {
                settleAfterTransition = false
                if remembersSize { TerminalGrid.remember(cols: g.cols, rows: g.rows) }
                // Only force the rows-1/rows flap when the settled grid equals
                // what the pty already has (net-zero toggle — a plain send would
                // dedup to no SIGWINCH). When the grid changed, one plain resize
                // is already a genuine SIGWINCH; the extra flap just writes more
                // mis-wrapped output on a streaming session (juancode-qxb).
                if let last = lastSent, last.cols == g.cols, last.rows == g.rows {
                    lastSent = nil
                    session.resizeLocal(cols: g.cols, rows: g.rows > 2 ? g.rows - 1 : g.rows + 1)
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, let g = self.lastGrid else { return }
                        self.lastSent = g
                        self.session.resizeLocal(cols: g.cols, rows: g.rows)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: work)
                } else {
                    sendResize(cols: g.cols, rows: g.rows)
                }
            } else {
                sendResize(cols: g.cols, rows: g.rows)
            }
        }

        /// Push a size to the pty, skipping no-op repeats. Also remember it as the
        /// size to spawn the *next* CLI at, so a freshly-opened session boots already
        /// matching the on-screen terminal instead of the tiny 80x24 default (which a
        /// fresh session would otherwise render its alt-screen at before any resize
        /// lands — the "opens short" bug).
        private func sendResize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            if remembersSize { TerminalGrid.remember(cols: cols, rows: rows) }
            if let last = lastSent, last.cols == cols, last.rows == rows { return }
            lastSent = (cols, rows)
            session.resizeLocal(cols: cols, rows: rows)
        }

        func detach() {
            // This local view is going away — release the shared grid so a remote
            // viewer (web / phone) can take control of the pty size (juancode-1th.1).
            session.releaseGrid(owner: GridArbiter.localOwner)
            if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
            activeObservers.forEach { NotificationCenter.default.removeObserver($0) }; activeObservers.removeAll()
            resizeWork?.cancel(); resizeWork = nil
            cancel?()
            cancel = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.write(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Coalesce a burst of resizes (panel-toggle relayout, window-edge drag)
            // into a single SIGWINCH. SwiftTerm has already resized its own grid for
            // rendering; we just avoid hammering the agent's TUI with intermediate
            // widths mid-stream, which interleaves partial redraws into garbage.
            guard newCols > 0, newRows > 0 else { return }
            scheduleResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Read-only terminal for an EXITED session: replays persisted scrollback so the
/// conversation history is visible, with no live pty behind it.
struct SwiftTermReplay: NSViewRepresentable {
    let scrollback: [UInt8]

    func makeNSView(context: Context) -> TerminalHostView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if !scrollback.isEmpty { tv.feed(byteArray: scrollback[...]) }
        // No `onDrop`: an exited session is read-only. The host still gives it
        // correct resize behaviour.
        return TerminalHostView(terminal: tv)
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }
}
