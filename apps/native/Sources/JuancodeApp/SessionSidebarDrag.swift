import SwiftUI
import JuancodeCore

/// Use the same transferable for native List rows and expanded scroll-box rows.
/// List's built-in move gesture alone does not export a session ID to pane drops.
struct SessionSidebarDrag: ViewModifier {
    let meta: SessionMeta
    let enabled: Bool
    let model: AppModel
    @State private var targeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .draggable(meta.id) {
                    Label(meta.title, systemImage: "rectangle.split.2x1")
                        .padding(8)
                        .background(Color.appSurface)
                }
                .dropDestination(for: String.self) { items, location in
                    guard let id = items.first, id != meta.id,
                          model.sessions.contains(where: { $0.id == id && $0.kind != .editor }) else { return false }
                    guard TerminalBackend.shared.useGhostty else { return false }
                    model.splitSession(meta.id, with: id, zone: .trailing)
                    return true
                } isTargeted: { targeted = $0 }
                .help("Drag onto a session to split.")
                .overlay {
                    if targeted && TerminalBackend.shared.useGhostty {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}
