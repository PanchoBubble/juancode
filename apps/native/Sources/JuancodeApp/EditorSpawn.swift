// A file opened from the rail's Diff tab looks like it grows out of the row that was
// clicked: a ghost card flies from the row to wherever the editor pane lands, then
// fades to reveal the editor underneath.
//
// The ghost is drawn at the window root because the session pane clips, and the
// row sits in the right rail, outside it. The live editor itself is never
// transformed: scaling a terminal surface mid-flight would make it reflow.

import SwiftUI

@MainActor @Observable
final class EditorSpawnCenter {
    struct Flight: Equatable {
        let id = UUID()
        /// The clicked row, in global coordinates.
        let from: CGRect
        let title: String
    }

    var flight: Flight?
    /// Where the visible session's editor pane sits, in global coordinates. Written
    /// by the pane on every layout, so it is current by the time a flight lands.
    var target: CGRect = .zero

    func launch(from: CGRect, title: String) {
        guard from != .zero else { return }
        flight = Flight(from: from, title: title)
    }
}

/// Mounted over the whole window; hit-testing off, so it never takes a click.
struct EditorSpawnOverlay: View {
    let center: EditorSpawnCenter

    var body: some View {
        GeometryReader { geo in
            if let flight = center.flight, center.target != .zero {
                let origin = geo.frame(in: .global).origin
                EditorSpawnGhost(from: flight.from.offsetBy(dx: -origin.x, dy: -origin.y),
                                 to: center.target.offsetBy(dx: -origin.x, dy: -origin.y),
                                 title: flight.title) {
                    if center.flight?.id == flight.id { center.flight = nil }
                }
                .id(flight.id)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EditorSpawnGhost: View {
    let from: CGRect
    let to: CGRect
    let title: String
    let done: () -> Void

    @State private var landed = false
    @State private var faded = false

    var body: some View {
        let r = landed ? to : from
        RoundedRectangle(cornerRadius: landed ? 8 : 4, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .overlay {
                RoundedRectangle(cornerRadius: landed ? 8 : 4, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
            }
            .overlay(alignment: .topLeading) {
                Label(title, systemImage: "doc.text")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .shadow(color: .black.opacity(0.5), radius: landed ? 18 : 4)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .opacity(faded ? 0 : 1)
            // The pane's frame can still settle once the editor opens into a split.
            .animation(.easeOut(duration: 0.15), value: to)
            .onAppear {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { landed = true }
                withAnimation(.easeOut(duration: 0.2).delay(0.32)) {
                    faded = true
                } completion: {
                    done()
                }
            }
    }
}
