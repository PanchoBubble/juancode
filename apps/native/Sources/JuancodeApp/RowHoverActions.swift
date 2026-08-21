import SwiftUI

/// Hover-revealed trailing actions for a list row — an ellipsis menu (the row's
/// context-menu items, made discoverable without a right-click) and a ✕.
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
    /// Pin/unpin this row (sticks it to the top of its group); nil hides the pin.
    var onTogglePin: (() -> Void)? = nil
    /// Whether the row is currently pinned — drives the glyph, its tint and the tooltip.
    var pinned: Bool = false
    /// Dismiss/restore this row — folds a sleeping session away (or brings it back);
    /// nil hides the chevron.
    var onToggleDismissed: (() -> Void)? = nil
    /// Whether the row is currently dismissed — flips the chevron to the undo.
    var dismissed: Bool = false
    var dismissHelp: String = ""
    /// Nil hides the ✕.
    let onCloseRequested: (() -> Void)?
    let closeHelp: String
    var glyphSize: CGFloat = 12

    private let corner: CGFloat = 7

    var body: some View {
        HStack(spacing: 1) {
            if let onTogglePin {
                Button(action: onTogglePin) {
                    // The chip is a button, so it shows the ACTION, not the state: a
                    // pinned row offers "unpin" (struck-through pin, tinted so the
                    // pill also answers "is this one pinned?" at a glance), an
                    // unpinned one the plain pin.
                    Image(systemName: pinned ? "pin.slash.fill" : "pin")
                        .font(.system(size: glyphSize - 1, weight: .semibold))
                        .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.borderless)
                .help(pinned ? "Unpin — let this session sort normally" : "Pin to top of this project")
                .clickCursor()
            }
            if let menuContent {
                Menu { menuContent() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: glyphSize, weight: .semibold))
                        // A Menu tints its own label from the control tint, so the
                        // container's `.foregroundStyle(.primary)` below never reaches
                        // it — the glyph rendered grey next to a white ✕. Set it here
                        // and match the tint so both glyphs read the same.
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(menuHelp)
                .clickCursor()
            }
            if let onToggleDismissed {
                Button(action: onToggleDismissed) {
                    // Same chevron the fold's own "Load more" button wears, pointed the
                    // way the row is about to travel: down into the fold, or back up
                    // out of it.
                    Image(systemName: dismissed ? "chevron.up.circle" : "chevron.down.circle")
                        .font(.system(size: glyphSize - 1, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(dismissHelp)
                .clickCursor()
            }
            if let onCloseRequested {
                Button(action: onCloseRequested) {
                    Image(systemName: "xmark")
                        .font(.system(size: glyphSize - 1, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(closeHelp)
                .clickCursor()
            }
        }
        // A borderless button tints its glyph with the accent colour, which reads as
        // low-contrast mud on the pill — force the full-contrast glyph instead (white
        // on the dark theme, near-black on the light one).
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(pill)
        // Keeps the pill clear of the row's own rounded edge.
        .padding(.trailing, 5)
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
