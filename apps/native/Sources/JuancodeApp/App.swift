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
/// Process-wide handle so the delegate can tear down live ptys on quit.
enum AppEnv {
    static var state: AppState?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

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
    @StateObject private var model: AppModel

    init() {
        let state: AppState
        do {
            state = try AppState()
        } catch {
            fatalError("Failed to open juancode database: \(error)")
        }
        _model = StateObject(wrappedValue: AppModel(appState: state))
        AppEnv.state = state

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
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") { model.showingNewSession = true }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
