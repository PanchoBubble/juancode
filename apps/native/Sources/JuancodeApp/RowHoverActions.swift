import SwiftUI

/// Hover-revealed trailing actions for a list row — ▶, pin and an ellipsis
/// menu (the row's context-menu items, Delete included, made discoverable without a
/// right-click).
///
/// Meant to be floated by the caller (`.overlay(alignment: .trailing)`) rather than
/// laid out inline: as inline content the buttons took width from the title, so every
/// title re-truncated and the text visibly jumped the instant the pointer entered a
/// row.
///
/// Drawn as a self-contained rounded pill — inset from the row's edges, hairline
/// border, drop shadow — rather than an edge-to-edge slab faded into the title. The
/// faded slab read as a smudge over the text; a pill with crisp edges reads as a
/// control floating *above* the row, which is what it is.
///
/// Shared by the sidebar's session rows and the Oracle rail's rows so the affordance
/// stays identical in both lists.
struct RowHoverActions: View {
    /// Items for the ellipsis menu; nil hides the menu.
    let menuContent: (() -> AnyView)?
    let menuHelp: String
    /// Run the project's run command in this row's checkout; nil hides the ▶.
    var onRun: (() -> Void)? = nil
    var runHelp: String = ""
    /// Pin/unpin this row (sticks it to the top of its group); nil hides the pin.
    var onTogglePin: (() -> Void)? = nil
    /// Whether the row is currently pinned — drives the glyph, its tint and the tooltip.
    var pinned: Bool = false
    var glyphSize: CGFloat = 12

    private let corner: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            if let onRun {
                Button(action: onRun) {
                    tile("play.fill", size: glyphSize - 3, accent: true)
                }
                .buttonStyle(.plain)
                .help(runHelp)
                .clickCursor()
            }
            if let onTogglePin {
                Button(action: onTogglePin) {
                    // The chip is a button, so it shows the ACTION, not the state: a
                    // pinned row offers "unpin" (struck-through pin, tinted so the
                    // pill also answers "is this one pinned?" at a glance), an
                    // unpinned one the plain pin.
                    tile(pinned ? "pin.slash.fill" : "pin", size: glyphSize - 3, accent: pinned)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin — let this session sort normally" : "Pin to top of this project")
                .clickCursor()
            }
            if let menuContent {
                // Last, so the destructive Delete lives one click deeper than the
                // everyday actions instead of as a ✕ a pixel from ▶ and the pin.
                Menu { menuContent() } label: {
                    tile("ellipsis", size: glyphSize - 2)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(menuHelp)
                .clickCursor()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(pill)
        // Keeps the pill clear of the row's own rounded edge.
        .padding(.trailing, 5)
    }

    /// One action as a small rounded tile — the Tickets rail's copy-link / Work on
    /// buttons, so hover actions read the same everywhere and each has its own hit
    /// target instead of bare glyphs crowded together.
    private func tile(_ symbol: String, size: CGFloat, accent: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(accent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
    }

    /// Frosted pill: a blur strong enough to fully hide the title behind it (a
    /// half-legible word under thin glass was the worst part of the old slab), lifted a
    /// touch brighter than the row and outlined so its edge is unambiguous.
    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return shape
            .fill(.ultraThickMaterial)
            .overlay(shape.fill(Color.appHairline(0.10)))
            .overlay(shape.strokeBorder(Color.appHairline(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
    }
}
