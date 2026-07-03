import SwiftUI
import JuancodeServices

/// "Kill Port" utility (opened from the sidebar toolbar): free up a stuck local dev
/// port. Lists the common dev-server ports plus any the user has saved, shows what's
/// LISTENing on each, and offers a one-click kill. A field at the bottom saves new
/// custom ports, which persist via `AppModel.savedPorts`.
struct KillPortSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Common dev-server ports suggested out of the box. juancode's own server/web
    /// (4280/5280) are included alongside the usual Vite/Next/CRA/etc. defaults.
    private static let suggested = [3000, 3001, 4200, 4280, 5173, 5280, 5432, 6379, 8000, 8080, 8081, 9229]

    /// port → who's listening (missing = not scanned yet, empty = free).
    @State private var listeners: [Int: [PortProcess]] = [:]
    /// Ports with a scan or kill in flight, so their row shows a spinner.
    @State private var busy: Set<Int> = []
    @State private var newPort = ""

    /// Suggested + saved, deduped and sorted — the rows to show.
    private var ports: [Int] {
        Array(Set(Self.suggested + model.savedPorts)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Kill Port").font(.title3).bold()
                if !busy.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await scanAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan all ports").clickCursor()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ports, id: \.self) { port in
                        PortRow(port: port,
                                listeners: listeners[port],
                                busy: busy.contains(port),
                                saved: model.savedPorts.contains(port),
                                kill: { Task { await kill(port) } },
                                forget: { model.removeSavedPort(port) })
                        Divider()
                    }
                }
            }
            Divider()
            addPortBar
        }
        .frame(width: 420, height: 480)
        .task { await scanAll() }
    }

    private var addPortBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            TextField("Save a port, e.g. 4000", text: $newPort)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addPort)
            Button("Save", action: addPort)
                .disabled(parsedNewPort == nil)
                .clickCursor()
        }
        .padding(10)
    }

    /// The entered port if it's a valid, not-yet-listed port number.
    private var parsedNewPort: Int? {
        guard let p = Int(newPort.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p), !ports.contains(p) else { return nil }
        return p
    }

    private func addPort() {
        guard let p = parsedNewPort else { return }
        model.addSavedPort(p)
        newPort = ""
        Task { await scan(p) }
    }

    /// Scan one port and store its listeners.
    private func scan(_ port: Int) async {
        busy.insert(port)
        defer { busy.remove(port) }
        listeners[port] = await PortKiller.listeners(on: port)
    }

    /// Scan every visible port concurrently.
    private func scanAll() async {
        await withTaskGroup(of: (Int, [PortProcess]).self) { group in
            for port in ports {
                busy.insert(port)
                group.addTask { (port, await PortKiller.listeners(on: port)) }
            }
            for await (port, found) in group {
                listeners[port] = found
                busy.remove(port)
            }
        }
    }

    private func kill(_ port: Int) async {
        busy.insert(port)
        defer { busy.remove(port) }
        let result = await PortKiller.kill(port: port)
        listeners[port] = result.stillInUse ? await PortKiller.listeners(on: port) : []
    }
}

/// One port's row: number, live status, and a Kill button (plus a forget button for
/// saved ports).
private struct PortRow: View {
    let port: Int
    /// nil = not scanned yet; empty = free; non-empty = in use.
    let listeners: [PortProcess]?
    let busy: Bool
    let saved: Bool
    let kill: () -> Void
    let forget: () -> Void

    private var inUse: Bool { !(listeners?.isEmpty ?? true) }

    var body: some View {
        HStack(spacing: 10) {
            Text(":\(String(port))")
                .font(.system(.body, design: .monospaced)).bold()
                .frame(width: 64, alignment: .leading)
            status
            Spacer()
            if saved {
                Button(action: forget) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Forget this saved port").clickCursor()
            }
            Button("Kill", action: kill)
                .disabled(!inUse || busy)
                .help(inUse ? "Kill the process on this port" : "Nothing to kill — port is free")
                .clickCursor()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var status: some View {
        if busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("working…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        } else if let listeners {
            if let first = listeners.first {
                let extra = listeners.count > 1 ? " +\(listeners.count - 1)" : ""
                Label("\(first.command) · pid \(String(first.pid))\(extra)", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Label("free", systemImage: "circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
        } else {
            Text("—").foregroundStyle(.secondary).font(.system(size: 12))
        }
    }
}
