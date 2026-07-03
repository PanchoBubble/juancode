import SwiftUI
import AppKit
import JuancodeCore

extension View {
    /// Web-like affordance for a clickable control: the pointing-hand cursor on
    /// hover **and** a subtle background highlight so the control visibly reacts
    /// (macOS gives plain buttons neither by default). The highlight is drawn as a
    /// negative-inset background, so it extends slightly beyond the label without
    /// changing the control's layout footprint — safe to drop onto any existing
    /// button. Applied app-wide via the many `.clickCursor()` call sites.
    func clickCursor() -> some View {
        modifier(ClickCursorModifier())
    }

    /// Pointing-hand cursor only (no highlight) — for larger custom hit areas where
    /// a background chip would look wrong (e.g. the terminal-drop zone).
    @ViewBuilder
    func pointerCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }
}

private struct ClickCursorModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                    .padding(-3) // extend the chip beyond the label; no layout shift
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerCursor()
            .animation(.easeOut(duration: 0.10), value: hovering)
    }
}

// MARK: - Screen-size-proportional panel defaults

/// Screen-size-proportional default panel widths. Each panel's width is a
/// fraction of the window, clamped to a band — the band's `max` caps the *auto*
/// default only; the user can still drag past it (up to the panel's own drag
/// max). Used only while the panel's width key has never been written: the first
/// manual drag persists via @AppStorage and wins from then on ("manual wins").
enum PanelAutoSize {
    static func width(window: CGFloat, fraction: CGFloat,
                      min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard window > 0 else { return lo }
        return Swift.min(hi, Swift.max(lo, window * fraction))
    }
}

// MARK: - Resize handle (juancode-n9y)

/// A draggable splitter with a genuinely usable hit area and clear hover feedback —
/// the thin 1pt dividers were nearly impossible to grab. The visible line is thin
/// at rest and thickens + brightens to the accent colour while hovered or dragged,
/// but the actual draggable zone is `hit` points wide regardless.
///
/// `axis: .vertical` is a vertical bar resized horizontally; `.horizontal` is a
/// horizontal bar resized vertically. The clamped size is written through `value`.
/// `invert` (default true) flips the drag direction for a handle sitting on the
/// near edge of the pane it resizes (drag toward the pane shrinks it).
struct DragResizeHandle: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    @Binding var value: Double
    let min: Double
    let max: Double
    var invert: Bool = true
    /// When true, the bound `value` is written only on drag *end* — during the drag a
    /// bright guide line previews where the edge will land, but nothing resizes yet.
    /// Use for panes hosting a live terminal: the CLI's full-screen TUI repaints on
    /// every intermediate width, so a live drag garbles it; committing once on release
    /// yields a single clean repaint instead.
    var previewOnly: Bool = false

    /// Width/height of the invisible grab zone.
    private let hit: CGFloat = 14
    @State private var hovering = false
    @State private var dragging = false
    /// `value` at the moment the drag began. `DragGesture.translation` is cumulative
    /// from the gesture start, so we apply it against this fixed anchor — adding it to
    /// the live (already-updated) `value` each frame compounds the translation and the
    /// size runs away to a clamp edge (the Oracle dock collapsing to its min width).
    @State private var dragStart: Double?
    /// In `previewOnly` mode, the live target while a drag is in flight; committed to
    /// `value` on release. Nil when not previewing.
    @State private var preview: Double?

    var body: some View {
        let active = hovering || dragging
        let lineColor = active ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.22)
        let thickness: CGFloat = active ? 3 : 1
        ZStack {
            Color.clear
            line(color: lineColor, thickness: thickness)
            if let target = preview {
                // Bright guide at the release target — the only thing that moves while
                // a previewOnly drag is in flight (the pane itself stays put).
                line(color: .accentColor, thickness: 3)
                    .offset(x: axis == .vertical ? guideOffset(target) : 0,
                            y: axis == .horizontal ? guideOffset(target) : 0)
            }
        }
        .frame(width: axis == .vertical ? hit : nil,
               height: axis == .horizontal ? hit : nil)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h {
                (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else if !dragging {
                NSCursor.pop()
            }
        }
        .gesture(
            // Measure in the global space: a live-resize handle (e.g. the project
            // sessions box) sits below the pane it grows, so relayout pushes the
            // handle itself under the cursor mid-drag. In `.local` space that view
            // movement feeds back into `translation` and the drag jitters; `.global`
            // is anchored to the screen and is unaffected. Identical to `.local` for
            // the preview handles, whose panes stay put during the drag.
            DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    dragging = true
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    let delta = axis == .vertical ? v.translation.width : v.translation.height
                    let signed = invert ? -delta : delta
                    let next = Swift.min(max, Swift.max(min, start + signed))
                    if previewOnly { preview = next } else { value = next }
                }
                .onEnded { _ in
                    if previewOnly, let target = preview {
                        // Committing the previewed size reflows any live terminal
                        // in one jump — mark it a layout transition so the pty gets
                        // one settled grid + a forced repaint instead of the raw
                        // relayout burst (juancode-1th.2).
                        LayoutTransitionGate.shared.begin()
                        value = target
                    }
                    preview = nil
                    dragging = false
                    dragStart = nil
                    if !hovering { NSCursor.pop() }
                }
        )
        .animation(.easeOut(duration: 0.10), value: active)
    }

    /// Point offset of the preview guide from the resting edge, given a target value.
    /// An `invert` handle (e.g. the Oracle's left edge) moves opposite to the value.
    private func guideOffset(_ target: Double) -> CGFloat {
        CGFloat((invert ? -1 : 1) * (target - value))
    }

    @ViewBuilder private func line(color: Color, thickness: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: thickness / 2)
            .fill(color)
            .frame(width: axis == .vertical ? thickness : nil,
                   height: axis == .horizontal ? thickness : nil)
    }
}
