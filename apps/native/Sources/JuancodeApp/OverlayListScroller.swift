import JuancodeCore
import SwiftUI

/// A thin scroll indicator floating over a scroll view's leading edge, shown while
/// the pointer is over it or it is scrolling. Replaces the system scroller: with a
/// mouse attached macOS draws a legacy one that is always visible and takes a column
/// from the rows, and SwiftUI resets any `scrollerStyle` set on its scroll view.
struct FloatingScrollIndicator: ViewModifier {
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var hovering = false
    @State private var scrolling = false
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: [CGFloat].self) { geo in
                    [geo.contentOffset.y, geo.contentSize.height, geo.containerSize.height]
                } action: { old, new in
                    offset = new[0]; contentHeight = new[1]; containerHeight = new[2]
                    if old[0] != new[0] { flash() }
                }
                .overlay(alignment: .topLeading) { thumb }
                .onHover { hovering = $0 }
        } else {
            content
        }
    }

    @ViewBuilder
    private var thumb: some View {
        let track = containerHeight - 4
        if contentHeight > containerHeight + 1, track > 0 {
            let height = max(28, track * containerHeight / contentHeight)
            let progress = min(1, max(0, offset / (contentHeight - containerHeight)))
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 5, height: height)
                .offset(x: 2, y: 2 + (track - height) * progress)
                .opacity(hovering || scrolling ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: hovering || scrolling)
                .allowsHitTesting(false)
        }
    }

    private func flash() {
        scrolling = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            await Nap.ms(800)
            if !Task.isCancelled { scrolling = false }
        }
    }
}
