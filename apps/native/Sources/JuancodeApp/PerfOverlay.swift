import SwiftUI

/// The performance HUD (⌥⌘P). A small, click-through readout pinned in a corner,
/// rendered only when `PerfMonitor.shared.visible`. See `PerfMonitor` for what each
/// number means; orange = a value worth worrying about.
struct PerfOverlay: View {
    @ObservedObject private var perf = PerfMonitor.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        if perf.visible {
            VStack(alignment: .leading, spacing: 2) {
                Text("PERF · ⌥⌘P").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                row("CPU", String(format: "%.0f%%", perf.cpuPercent), warn: perf.cpuPercent > 90)
                row("Mem", String(format: "%.0f MB", perf.memoryMB))
                row("Worst frame", String(format: "%.0f ms", perf.worstFrameMs), warn: perf.worstFrameMs > 32)
                row("Dropped", "\(perf.droppedFrames)/s", warn: perf.droppedFrames > 0)
                row("Feed", String(format: "%.0f KB/s · %d×", perf.feedKBPerSec, perf.feedCallsPerSec))
                row("View bodies", "\(perf.bodyEvalsPerSec)/s", warn: perf.bodyEvalsPerSec > 120)
                row("Live sessions", "\(liveCount)")
            }
            .font(.system(size: 10, weight: .medium).monospaced())
            .padding(8)
            .background(Color.appSurface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appHairline(0.15)))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    private var liveCount: Int { model.sessions.filter { model.isLive($0.id) }.count }

    private func row(_ key: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(key).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).foregroundStyle(warn ? .orange : .primary)
            Spacer(minLength: 0)
        }
    }
}
