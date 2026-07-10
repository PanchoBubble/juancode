import SwiftUI
import AppKit
import JuancodeCore
import JuancodePersistence
import JuancodeServer

/// A bare SPM executable launches with background (accessory) activation, so its
/// window never appears and it isn't in the Dock. Promote it to a regular
/// foreground app on launch and bring it to front. (A signed `.app` bundle with
/// an Info.plist — juancode-u34.9 — does this declaratively; until then we do it
/// in code so `swift run juancode` shows a window.)
/// Process-wide handle so the delegate can tear down live ptys on quit. Written
/// in `JuancodeApp.init` and read in `applicationWillTerminate` — both run on the
/// main actor, so confine the static there rather than guard it.
@MainActor
enum AppEnv {
    static var state: AppState?
    /// The app model, for delegate paths that need UI state — the quit-time
    /// work-at-risk summary reads its last scan (juancode-rxu).
    static var model: AppModel?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    /// Held for the app's lifetime to opt out of App Nap. Without it, minimizing
    /// the window lets macOS nap the process: the pty-read queue is throttled (so
    /// the agent blocks on a full pipe) and the on-demand Metal terminal view stops
    /// getting fresh draws — the agent looks frozen after restore. The
    /// `AllowingIdleSystemSleep` variant disables App Nap but still lets the Mac
    /// itself idle-sleep, so we're not pinning the whole machine awake.
    private var activityToken: NSObjectProtocol?
    private var restoreObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Set the Dock/app-switcher icon in code: when the binary is exec'd
        // straight from the terminal (see scripts/dev-app.sh) LaunchServices never
        // registers the bundle's CFBundleIconFile, so the Info.plist icon alone
        // leaves a generic Dock tile. Load AppIcon.icns from the bundle Resources.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Streaming live terminal sessions")

        // On-demand Metal views can come back from a minimize showing a stale frame
        // (no new pty output ⇒ no `setNeedsDisplay`). Force a repaint of all window
        // content when the app reactivates or a window is de-miniaturized.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didDeminiaturizeNotification] {
            restoreObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Delivered on the main queue, so assuming main-actor isolation is safe.
                MainActor.assumeIsolated { Self.refreshAllWindows() }
            })
        }

        // A fullscreen toggle animates the window through a burst of intermediate
        // geometries — the same "discrete layout transition" as a panel toggle, so
        // gate it too: the terminal coordinators hold every intermediate grid and
        // assert the settled one once, with a forced repaint (juancode-1th.2). The
        // will* window covers the animation; the did* re-arm covers any trailing
        // layout pass after it completes.
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            restoreObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                LayoutTransitionGate.shared.begin(for: .milliseconds(1000))
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            restoreObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                LayoutTransitionGate.shared.begin(for: .milliseconds(350))
            })
        }

        // Apply the user's saved appearance (juancode light/dark toggle) to the window
        // chrome at launch; defaults to dark to preserve the app's pure-black look that
        // blends into the SwiftTerm views. Runtime changes go through
        // `AppModel.applyAppearance`. The SwiftUI tree follows via RootView's
        // `preferredColorScheme`.
        NSApp.appearance = ThemePreference.persisted.nsAppearance

        // Make terminal Ctrl-C (SIGINT) and SIGTERM quit the app cleanly. The GUI
        // run loop doesn't honour the default SIGINT disposition, so we monitor
        // the signals via dispatch sources (which fire regardless of disposition)
        // and route them through the normal terminate path (→ applicationWillTerminate).
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Force every window's view tree to repaint — defeats the stale-frame an
    /// on-demand Metal view can show after a minimize/restore cycle.
    @MainActor private static func refreshAllWindows() {
        for window in NSApp.windows { markNeedsDisplay(window.contentView) }
    }

    @MainActor private static func markNeedsDisplay(_ view: NSView?) {
        guard let view else { return }
        view.setNeedsDisplay(view.bounds)
        for sub in view.subviews { markNeedsDisplay(sub) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnv.state?.shutdown() // kill live sessions + ephemeral ptys on quit
    }
}

/// The native juancode app (juancode-u34.4): the local SwiftUI shell AND the host
/// of the embedded WS+HTTP server. The local view and remote browser/phone
/// clients are both subscribers to the one in-process `SessionRegistry` — the
/// pty always runs here on the Mac (the u34 prime directive). Run: `swift run juancode`.
@main
struct JuancodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var oracle: OracleModel
    @State private var shortcuts = Shortcuts()

    init() {
        // Open the on-disk store. If that fails (corrupt file, locked, unwritable
        // data dir) don't crash — fall back to an ephemeral in-memory store so the
        // app still runs this launch, and carry the reason so RootView can surface
        // a recovery sheet offering to reset the on-disk DB (juancode-4zk). Only a
        // failure to open even an in-memory database is truly fatal.
        let dbPath = GRDBStore.defaultPath()
        let state: AppState
        var degradedReason: String? = nil
        do {
            state = try AppState()
        } catch {
            NSLog("juancode: on-disk database failed to open (\(dbPath)): \(error)")
            do {
                state = AppState(store: try GRDBStore(inMemory: true))
                degradedReason = String(describing: error)
            } catch {
                fatalError("Failed to open even an in-memory database: \(error)")
            }
        }
        let appModel = AppModel(appState: state, degradedReason: degradedReason,
                                corruptDbPath: degradedReason != nil ? dbPath : nil)
        _model = State(wrappedValue: appModel)
        _oracle = State(wrappedValue: OracleModel(app: appModel))
        AppEnv.state = state
        AppEnv.model = appModel

        // Boot the embedded server so remote clients can attach to the same
        // registry. Best-effort: if the port is taken (e.g. a dev server is
        // running) the local shell still works fully. `handleSignals: false` so
        // the server doesn't swallow the terminal's Ctrl-C — the app owns its
        // lifecycle (Cmd-Q, or Ctrl-C terminates the process).
        let host = ProcessInfo.processInfo.environment["JUANCODE_HOST"] ?? "127.0.0.1"
        Task.detached {
            do {
                try await JuancodeServer.run(state: state, host: host, port: Config.port, handleSignals: false)
            } catch {
                NSLog("juancode: embedded server did not start: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(oracle)
                .environment(shortcuts)
                .overlay(alignment: .topTrailing) { PerfOverlay().environment(model) }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                // ⌘N clones the selected session's agent + cwd (sheet when nothing
                // is selected); ⌘⇧N always opens the full New Session sheet. All
                // these key-equivalents are user-rebindable (juancode-oe4) — see
                // Shortcuts.swift and the Settings → Shortcuts pane.
                Button("New Session (same agent & folder)") {
                    performShortcut(.newSessionSameProject, model: model, oracle: oracle)
                }
                .appShortcut(.newSessionSameProject, shortcuts)
                Button("New Session…") {
                    performShortcut(.newSessionSheet, model: model, oracle: oracle)
                }
                .appShortcut(.newSessionSheet, shortcuts)
                // ⌘K opens the session jump palette: fuzzy-find any session or
                // worktree and switch to it; needs-attention sessions sort first
                // (juancode-dr0).
                Button("Jump to Session…") {
                    performShortcut(.jumpPalette, model: model, oracle: oracle)
                }
                .appShortcut(.jumpPalette, shortcuts)
                // ⌘P Quick Open: fuzzy-find and open a file in the selected session's
                // worktree (open in the editor pane, reveal in Changes, or reference it
                // in the prompt).
                Button("Quick Open File…") {
                    performShortcut(.quickOpen, model: model, oracle: oracle)
                }
                .appShortcut(.quickOpen, shortcuts)
                // ⌘⇧K opens the prompt-template palette: pick a saved prompt and
                // insert (or insert+send) it into the active session (juancode-2vd).
                Button("Prompt Templates…") {
                    performShortcut(.promptTemplates, model: model, oracle: oracle)
                }
                .appShortcut(.promptTemplates, shortcuts)
                // ⌘L opens the session-template launcher: pick a saved launch preset
                // (agent + folder + knobs + prompt) and spawn one or N sessions from
                // it (juancode-a2r).
                Button("Session Templates…") {
                    performShortcut(.sessionTemplates, model: model, oracle: oracle)
                }
                .appShortcut(.sessionTemplates, shortcuts)
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Performance HUD") {
                    performShortcut(.togglePerfHud, model: model, oracle: oracle)
                }
                .appShortcut(.togglePerfHud, shortcuts)
                Toggle("Turn-End Notifications", isOn: Binding(
                    get: { model.notifyOnTurnEnd },
                    set: { model.notifyOnTurnEnd = $0 }))
                // Block idle system sleep so a long prompt isn't cut off when you
                // step away. ⌃⇧A toggles it from anywhere.
                Toggle("Keep Awake", isOn: Binding(
                    get: { model.keepAwake },
                    set: { model.keepAwake = $0 }))
                    .appShortcut(.keepAwake, shortcuts)
                // Force the live terminal to re-measure + SIGWINCH when a resize left
                // the pane mis-sized and the auto-resync was missed. ⌃⇧R from anywhere.
                Button("Recalculate Terminal Geometry") {
                    performShortcut(.recalcGeometry, model: model, oracle: oracle)
                }
                .appShortcut(.recalcGeometry, shortcuts)
                // ⌃Z hard-refreshes the visible terminal (Oracle chat when the dock
                // is open, else the session pane) — rebuild + replay scrollback.
                Button("Refresh Terminal") {
                    performShortcut(.refreshTerminal, model: model, oracle: oracle)
                }
                .appShortcut(.refreshTerminal, shortcuts)
                // ⌃S shows/hides the projects sidebar column.
                Button("Toggle Projects Panel") {
                    performShortcut(.toggleProjects, model: model, oracle: oracle)
                }
                .appShortcut(.toggleProjects, shortcuts)
                // ⌘⇧C jumps straight to the selected session's working-tree diff and
                // clears its review badge.
                Button("Open Changes for Current Session") {
                    performShortcut(.openChangesForCurrentSession, model: model, oracle: oracle)
                }
                .appShortcut(.openChangesForCurrentSession, shortcuts)
                // ⌘⇧E shows/hides the file-tree sidebar over the selected session's
                // worktree (the Files side-panel tab).
                Button("Toggle File Tree") {
                    performShortcut(.toggleFileTree, model: model, oracle: oracle)
                }
                .appShortcut(.toggleFileTree, shortcuts)
                // ⌃T toggles the bottom shell-terminal panel from anywhere. A menu
                // key-equivalent fires even while the SwiftTerm view holds focus.
                Button("Toggle Terminal") {
                    performShortcut(.toggleTerminal, model: model, oracle: oracle)
                }
                .appShortcut(.toggleTerminal, shortcuts)
                // ⌘E opens the selected session's worktree in $EDITOR (nvim) as a
                // first-class session, so the editor lands in the agent's checkout.
                Button("Open Editor for Session") {
                    performShortcut(.openEditor, model: model, oracle: oracle)
                }
                .appShortcut(.openEditor, shortcuts)
                // Global Oracle + issues access (juancode-6sw). ⌃Space toggles the
                // Oracle panel from anywhere; ⌘⇧I jumps straight to global issues.
                Button("Oracle") {
                    performShortcut(.oracle, model: model, oracle: oracle)
                }
                .appShortcut(.oracle, shortcuts)
                Button("Global Issues") {
                    performShortcut(.globalIssues, model: model, oracle: oracle)
                }
                .appShortcut(.globalIssues, shortcuts)
                // ⌃F drops focus into the sidebar's "Filter sessions…" field from
                // anywhere so you can start a find without reaching for the mouse.
                Button("Find Sessions") {
                    performShortcut(.focusSessionSearch, model: model, oracle: oracle)
                }
                .appShortcut(.focusSessionSearch, shortcuts)
                // ⌘F opens the in-pane find bar over the visible terminal — search
                // that session's scrollback (juancode-972).
                Button("Find in Terminal") {
                    performShortcut(.findInTerminal, model: model, oracle: oracle)
                }
                .appShortcut(.findInTerminal, shortcuts)
                // Terminal font zoom (juancode-fry): one global level across every
                // pane, the Oracle dock, and the bottom panel. ⌘= / ⌘− / ⌘0 (⌘+ also
                // zooms in via the key monitor). Applied live — no surface rebuild.
                Button("Increase Terminal Font") {
                    performShortcut(.terminalZoomIn, model: model, oracle: oracle)
                }
                .appShortcut(.terminalZoomIn, shortcuts)
                Button("Decrease Terminal Font") {
                    performShortcut(.terminalZoomOut, model: model, oracle: oracle)
                }
                .appShortcut(.terminalZoomOut, shortcuts)
                Button("Reset Terminal Font") {
                    performShortcut(.terminalZoomReset, model: model, oracle: oracle)
                }
                .appShortcut(.terminalZoomReset, shortcuts)
            }
        }

        // Standard ⌘, Settings window — editable shortcuts + session behaviour.
        Settings {
            TabView {
                ShortcutSettingsView()
                    .environment(shortcuts)
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                SessionSettingsView()
                    .environment(model)
                    .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
            }
        }
    }
}
