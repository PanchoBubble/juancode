import SwiftUI
import JuancodeCore

/// "Remote is driving" overlay (juancode-2t4), shown top-right over the visible
/// terminal while a web/phone viewer owns this session's pty grid
/// (`AppModel.remoteGridOwner`). Expanded it names the state and offers a
/// one-click take-back — the local pane preempts by policy, so a geometry
/// resync (one genuine SIGWINCH at the surface grid) is all a take-back needs.
/// After a few seconds it collapses to a slim glyph-only capsule so it never
/// occludes the TUI (Orca's MobileDriverOverlay collapse); hovering re-expands
/// it. Appears/disappears live via the grid-change bridge in `AppModel.watch`,
/// so re-claiming the grid by any route auto-dismisses it.
struct RemoteDriveOverlay: View {
    let owner: String
    let takeBack: () -> Void
    @State private var collapsed = false
    @State private var hovering = false

    private var expanded: Bool { hovering || !collapsed }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
            if expanded {
                Text("Remote is driving · \(RemoteDriveBadge.shortOwner(owner))")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Button(action: takeBack) {
                    Text("Take back")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.3), in: Capsule())
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Re-assert this pane's grid — the remote viewer letterboxes to it")
            }
        }
        .padding(.horizontal, expanded ? 10 : 7)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .background(.orange.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 1))
        .foregroundStyle(.orange)
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .onHover { hovering = $0 }
        .task {
            try? await Task.sleep(for: .seconds(RemoteDriveBadge.collapseAfterSeconds))
            collapsed = true
        }
        .help("A remote viewer (web / phone) owns this terminal's grid (client \(owner))")
    }
}
