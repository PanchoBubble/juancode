import AppKit
import Foundation
import SwiftTerm

// A Swift window rendering a session owned by the Rust core.
//
// The point of the spike: the Swift UI needs no FFI and no new protocol to talk to
// `juancoded`. It speaks the wire protocol that already exists — the same one
// remote clients use today — so the pty living in another process is invisible to
// the view layer. Keystrokes go out as `input`, resizes as `resize`, and the
// `output` stream feeds SwiftTerm exactly as the in-process path does.
//
// Everything here is throwaway. The real seam is CoreClient (juancode-52e8.1).

let defaultURL = "ws://127.0.0.1:4290/ws"

struct Args {
    var url: String = ProcessInfo.processInfo.environment["JUANCODED_WS"] ?? defaultURL
    var cwd: String = FileManager.default.currentDirectoryPath
    var provider: String = "claude"
    /// Attach to an existing session instead of creating one.
    var sessionId: String?
    /// Dump the rendered grid to stderr after N seconds and quit. Lets the spike
    /// prove what the Swift view actually rendered without a screen capture.
    var dumpAfter: Double?

    init(_ argv: [String]) {
        var it = argv.makeIterator()
        _ = it.next() // binary
        while let arg = it.next() {
            switch arg {
            case "--url": url = it.next() ?? url
            case "--cwd": cwd = it.next() ?? cwd
            case "--provider": provider = it.next() ?? provider
            case "--session": sessionId = it.next()
            case "--dump-after": dumpAfter = it.next().flatMap(Double.init)
            default: break
            }
        }
    }
}

let args = Args(CommandLine.arguments)

/// Client end of the wire protocol: just enough of it to render one session.
final class CoreConnection: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var sessionId: String?
    private var inputSeq = 0
    private var pendingGrid: (cols: Int, rows: Int)?

    var onOutput: (([UInt8]) -> Void)?
    var onAttached: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    func connect() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        guard let url = URL(string: args.url) else {
            onStatus?("bad url: \(args.url)")
            return
        }
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onStatus?("socket closed: \(error.localizedDescription)")
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "serverInfo":
            let version = json["protocolVersion"] as? Int ?? 0
            let caps = (json["capabilities"] as? [String]) ?? []
            onStatus?("core protocol v\(version), capabilities: \(caps.joined(separator: ", "))")
            // Feature-detection, the mechanism that makes a narrower core safe to
            // talk to: only ask for acks if this core says it implements them.
            if let existing = args.sessionId {
                let grid = pendingGrid ?? (cols: 100, rows: 30)
                send(["type": "attach", "sessionId": existing, "cols": grid.cols, "rows": grid.rows])
            } else {
                let grid = pendingGrid ?? (cols: 100, rows: 30)
                send([
                    "type": "create", "provider": args.provider, "cwd": args.cwd,
                    "cols": grid.cols, "rows": grid.rows,
                ])
            }
        case "created", "attached":
            guard let session = json["session"] as? [String: Any],
                  let id = session["id"] as? String else { return }
            sessionId = id
            if let scrollback = json["scrollback"] as? String, !scrollback.isEmpty {
                onOutput?(Array(scrollback.utf8))
            }
            onStatus?("\(type): \(id) [\(session["provider"] ?? "?")] in \(session["cwd"] ?? "?")")
            onAttached?(id)
        case "output":
            guard let data = json["data"] as? String else { return }
            onOutput?(Array(data.utf8))
        case "resizeAck":
            let applied = json["applied"] as? Bool ?? false
            let cols = json["cols"] as? Int ?? 0
            let rows = json["rows"] as? Int ?? 0
            onStatus?("resizeAck \(cols)x\(rows) applied=\(applied)")
        case "exit":
            let code = json["exitCode"] as? Int
            onStatus?("session exited (code \(code.map(String.init) ?? "nil"))")
        case "unresumable":
            onStatus?("unresumable: \(json["reason"] ?? "?")")
        case "error":
            onStatus?("core error: \(json["message"] ?? "?")")
        default:
            break
        }
    }

    func write(_ text: String) {
        guard let sessionId else { return }
        inputSeq += 1
        send(["type": "input", "sessionId": sessionId, "data": text, "seq": inputSeq])
    }

    func resize(cols: Int, rows: Int) {
        pendingGrid = (cols, rows)
        guard let sessionId else { return }
        inputSeq += 1
        send([
            "type": "resize", "sessionId": sessionId,
            "cols": cols, "rows": rows, "seq": inputSeq,
        ])
    }

    func kill() {
        guard let sessionId else { return }
        send(["type": "kill", "sessionId": sessionId])
    }
}

/// A plain `TerminalView` fed from the socket. Deliberately NOT
/// `LocalProcessTerminalView`: the pty is not ours, it is the Rust core's, which is
/// the whole point being proven.
final class RemoteTerminalView: TerminalView, TerminalViewDelegate {
    let core = CoreConnection()

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        core.onOutput = { [weak self] bytes in
            DispatchQueue.main.async { self?.feed(byteArray: bytes[...]) }
        }
        core.onStatus = { message in FileHandle.standardError.write(Data(("[spike] " + message + "\n").utf8)) }
        core.connect()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The visible grid as text, read out of the view's OWN terminal — so what it
    /// prints is what the Swift client rendered, not what the socket delivered.
    func renderedGrid() -> String {
        let terminal = getTerminal()
        var rows: [String] = []
        for r in 0..<terminal.rows {
            guard let line = terminal.getLine(row: r) else { continue }
            var text = ""
            var i = 0
            let limit = min(terminal.cols, line.count)
            while i < limit {
                let width = line.getWidth(index: i)
                if width == 0 { i += 1; continue }
                let raw = terminal.getCharacter(for: line[i])
                text.append(raw == "\u{0}" ? " " : raw)
                i += 1
            }
            rows.append(text.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression))
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        core.write(text)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        core.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        window?.title = title.isEmpty ? "juancoded (Rust core)" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var terminal: RemoteTerminalView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "juancoded (Rust core) — \(args.url)"
        terminal = RemoteTerminalView(frame: frame)
        terminal.autoresizingMask = [.width, .height]
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)

        if let after = args.dumpAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                let grid = self.terminal.renderedGrid()
                FileHandle.standardError.write(Data("[spike] rendered grid follows\n".utf8))
                FileHandle.standardError.write(Data((grid + "\n").utf8))
                self.terminal.core.kill()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave nothing running behind the window.
        terminal?.core.kill()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
