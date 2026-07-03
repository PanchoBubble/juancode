import SwiftUI
import AppKit
import SwiftTerm
import JuancodeServices

/// One open editor overlay: the session it belongs to, the file being edited, and
/// its live ephemeral pty. `Identifiable` for SwiftUI identity / transitions. Held
/// on `AppModel` (a single overlay at a time) so the floating editor can be hosted
/// at the window root rather than trapped inside the narrow Changes side panel.
struct EditorTarget: Identifiable {
    let id = UUID()
    let sessionId: String
    let file: String
    let pty: EphemeralPty
}

/// Floating, resizable host for the one open editor (juancode editor window). Dims
/// the window and centers a large panel whose size the user can drag to change; the
/// size is remembered app-wide via `@AppStorage`. Rendered once at the window root
/// (`RootView`) so it floats over the whole window rather than the ~420pt side
/// panel a `.sheet` from `ChangesPanel` was confined near.
struct EditorHost: View {
    @Environment(AppModel.self) private var model
    /// Persisted panel size (drag the right / bottom edge). Clamped to the window.
    @AppStorage("editor.overlay.width") private var width: Double = 1040
    @AppStorage("editor.overlay.height") private var height: Double = 720

    var body: some View {
        ZStack {
            if let target = model.editing {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                GeometryReader { geo in
                    // Cap to the window (minus a margin) so a small window can't push
                    // the panel off-screen; floor so it stays a usable editor grid.
                    let maxW = Swift.max(640, geo.size.width - 64)
                    let maxH = Swift.max(420, geo.size.height - 64)
                    let w = Swift.min(maxW, Swift.max(640, width))
                    let h = Swift.min(maxH, Swift.max(420, height))
                    EditorOverlay(
                        file: target.file,
                        pty: target.pty,
                        width: $width, height: $height,
                        maxWidth: maxW, maxHeight: maxH,
                        onExit: { [id = target.id] in
                            Task { @MainActor in model.closeEditorOverlay(id) }
                        },
                        onForceClose: { target.pty.kill(); model.closeEditorOverlay(target.id) })
                        .frame(width: w, height: h)
                        .frame(maxWidth: .infinity, maxHeight: .infinity) // center in window
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.editing?.id)
    }
}

/// SwiftUI port of the web `EditorModal`. A terminal panel that opens ONE file in
/// the user's real editor (`$VISUAL`/`$EDITOR`, default nvim) through an ephemeral
/// pty, so the file is edited with the genuine editor config (plugins, colors,
/// tree-sitter). On the editor exiting (e.g. `:q`) the overlay dismisses and the
/// caller refetches the diff; the pty is killed on dismiss if still alive.
///
/// Presented as a large, resizable floating window by `EditorHost`. Lifecycle: the
/// pty is spawned by `AppModel.openEditorOverlay` BEFORE this view appears (so the
/// binding is non-optional and never races the handshake), handed in here, rendered
/// by `SwiftTermEphemeral`, and torn down by `onExit`/`onDisappear`.
struct EditorOverlay: View {
    let file: String
    let pty: EphemeralPty
    /// Panel size, owned by `EditorHost`; the edge handles write through these.
    @Binding var width: Double
    @Binding var height: Double
    /// Upper bounds for the resize handles (the window size minus a margin).
    let maxWidth: Double
    let maxHeight: Double
    /// Called (on the main actor) once the editor pty has exited, so the overlay
    /// should dismiss. `@Sendable` because the pty's exit fires off the main thread.
    let onExit: @Sendable () -> Void
    /// User-initiated force close (kills the pty, discarding an unsaved buffer).
    let onForceClose: () -> Void

    private static let minWidth: Double = 640
    private static let minHeight: Double = 420

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Editing").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(file)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(":q in the editor to close")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Force close", action: onForceClose)
                    .controlSize(.small)
                    .help("Force close (discards an unsaved buffer)")
                    .clickCursor()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            SwiftTermEphemeral(pty: pty, onExit: onExit)
                .background(Color.black)
        }
        .background(Color.appPanel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appHairline(0.12)))
        .shadow(radius: 30)
        // Drag the right / bottom edge to resize; the size is remembered app-wide.
        .overlay(alignment: .trailing) {
            DragResizeHandle(axis: .vertical, value: $width,
                             min: Self.minWidth, max: maxWidth, invert: false)
        }
        .overlay(alignment: .bottom) {
            DragResizeHandle(axis: .horizontal, value: $height,
                             min: Self.minHeight, max: maxHeight, invert: false)
        }
    }
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, driven by a live `EphemeralPty`
/// (an editor/shell pty). The sibling of `SwiftTermLive` for the non-persisted,
/// non-replayed ephemeral ptys: it subscribes to the pty's raw output fan-out, routes
/// keystrokes/resize back, and reports exit. Output feed + exit both hop to the main
/// thread (AppKit) since the pty callbacks arrive on a background queue.
struct SwiftTermEphemeral: NSViewRepresentable {
    let pty: EphemeralPty
    /// True while the hosting panel is kept mounted but collapsed (keep-alive
    /// toggle, juancode-it1): freezes pty sizing so the collapse animation's
    /// shrinking grids never reach the shell.
    var hidden: Bool = false
    let onExit: @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pty: pty, onExit: onExit) }

    func makeNSView(context: Context) -> TerminalHostView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(to: tv)
        // Sync the freshly spawned pty to the view's real size so the editor repaints.
        let t = tv.getTerminal()
        pty.resize(cols: t.cols, rows: t.rows)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        let host = TerminalHostView(terminal: tv)
        host.onDrop = { [pty] text in pty.write(Array(text.utf8)) }
        return host
    }

    // SwiftUI calls this in the same transaction that flips `hidden` — before any
    // intermediate animation frame resizes the NSView — so the freeze lands first.
    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        context.coordinator.setHidden(hidden)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }

    static func dismantleNSView(_ nsView: TerminalHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let pty: EphemeralPty
        /// Marked `@Sendable` so it can be invoked from the pty's exit callback
        /// (which runs off the main thread); `EditorOverlay` builds it to hop to the
        /// main actor itself.
        private let onExit: @Sendable () -> Void
        private weak var view: TerminalView?
        private var cancelOutput: (() -> Void)?
        private var cancelExit: (() -> Void)?
        private var wheelMonitor: Any?
        private var resizeWork: DispatchWorkItem?
        /// True while the hosting panel is collapsed (keep-alive toggle): resize
        /// requests are recorded but never forwarded to the pty. See the Ghostty
        /// counterpart's `sizingFrozen`.
        private var sizingFrozen = false
        /// Latest grid the view reported while frozen; flushed once on unhide.
        private var frozenGrid: (cols: Int, rows: Int)?

        init(pty: EphemeralPty, onExit: @escaping @Sendable () -> Void) {
            self.pty = pty
            self.onExit = onExit
        }

        /// Freeze/unfreeze pty sizing with the panel's visibility. On unhide, send
        /// the current (restored-bounds) grid once.
        @MainActor
        func setHidden(_ hidden: Bool) {
            guard hidden != sizingFrozen else { return }
            sizingFrozen = hidden
            if hidden {
                resizeWork?.cancel(); resizeWork = nil
            } else {
                let g = view.map { (cols: $0.getTerminal().cols, rows: $0.getTerminal().rows) }
                    ?? frozenGrid
                frozenGrid = nil
                if let g, g.cols >= 10, g.rows >= 3 { pty.resize(cols: g.cols, rows: g.rows) }
            }
        }

        func attach(to tv: TerminalView) {
            view = tv
            wheelMonitor = installWheelForwarding(on: tv)
            cancelOutput = pty.onOutput { [weak tv] bytes in
                DispatchQueue.main.async { tv?.feed(byteArray: bytes[...]) }
            }
            // Capture the exit handler directly (not `self`) so the `@Sendable`
            // closure doesn't pull in the non-Sendable Coordinator.
            let fire = onExit
            cancelExit = pty.onExit { _ in fire() }
        }

        func detach() {
            if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
            resizeWork?.cancel(); resizeWork = nil
            cancelOutput?(); cancelOutput = nil
            cancelExit?(); cancelExit = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty.write(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Collapsed keep-alive panel: record the grid, never forward it — the
            // unhide path flushes once. Also floor tiny grids (see the Ghostty
            // counterpart's `send`): the collapse animation can produce a small-but-
            // valid grid on its way to zero that would rewrap the shell's scrollback.
            if sizingFrozen || newCols < 10 || newRows < 3 {
                frozenGrid = (newCols, newRows)
                return
            }
            // Coalesce resize bursts into one SIGWINCH (see SwiftTermLive).
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pty.resize(cols: newCols, rows: newRows) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: work)
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
