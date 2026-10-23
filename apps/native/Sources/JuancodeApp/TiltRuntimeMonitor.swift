import SwiftUI
import JuancodeCore

@MainActor @Observable
final class TiltRuntimeMonitor {
    var runtimes: [TiltRuntime] = []
    var unavailable = false

    func refresh() async {
        do {
            runtimes = try await TiltRuntime.scan()
            unavailable = false
        } catch {
            runtimes = []
            unavailable = true
        }
    }

    func inProject(_ path: String) -> [TiltRuntime] {
        runtimes.filter { $0.project == TiltRuntime.canonical(path) }
    }
}

struct TiltRuntimeBadge: View {
    let monitor: TiltRuntimeMonitor
    let path: String
    var project = false

    var body: some View {
        let runs = project ? monitor.inProject(path) : monitor.runtimes.filter {
            $0.checkout == TiltRuntime.canonical(path)
        }
        if !runs.isEmpty {
            Label(project ? "Running in \(Array(Set(runs.map(\.name))).sorted().joined(separator: ", "))" : "Running",
                  systemImage: "play.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.green)
                .lineLimit(1)
                .help("Tilt is running in \(runs.map(\.checkout).joined(separator: ", ")). Service health is not checked.")
        } else if monitor.unavailable {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("Tilt running status is unavailable")
        }
    }
}
