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

    func inCheckout(_ path: String) -> [TiltRuntime] {
        runtimes.filter { $0.checkout == TiltRuntime.canonical(path) }
    }
}

/// The project header shows a bare glyph (its row of buttons has no room for copy, and
/// a label there truncated the project name); a session row shows a small labelled
/// capsule on its badge line. Which checkout owns the stack is in the tooltip.
struct TiltRuntimeBadge: View {
    let monitor: TiltRuntimeMonitor
    let path: String
    var project = false

    var body: some View {
        let runs = project ? monitor.inProject(path) : monitor.inCheckout(path)
        let help = "Tilt is running in \(runs.map(\.checkout).joined(separator: ", ")). Service health is not checked."
        if !runs.isEmpty {
            if project {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .frame(width: 22, height: 22)
                    .help(help)
            } else {
                Label("Stack running", systemImage: "play.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                    .help(help)
            }
        } else if monitor.unavailable {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("Tilt running status is unavailable")
        }
    }
}
