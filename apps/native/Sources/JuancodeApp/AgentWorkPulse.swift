import SwiftUI

/// Gently breathe the provider logo while working, without changing row layout.
struct AgentWorkPulse: ViewModifier {
    let working: Bool

    func body(content: Content) -> some View {
        AgentWorkMotion(working: working) { phase in
            content.scaleEffect(phase.map { 1 + 0.08 * sin($0 * 2 * .pi) } ?? 1)
        }
    }
}

/// A bright comet repeatedly sweeps down the rail; the dim track keeps the
/// activity color readable between passes. Neither animation changes row layout.
struct AgentWorkRail: View {
    let working: Bool
    let tint: Color

    var body: some View {
        AgentWorkMotion(working: working) { phase in
            Rectangle().fill(tint.opacity(phase == nil ? 1 : 0.3))
                .overlay {
                    if let phase {
                        GeometryReader { geometry in
                            let length = max(18, geometry.size.height * 0.55)
                            Rectangle()
                                .fill(LinearGradient(colors: [.clear, tint, .white, tint, .clear],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(height: length)
                                .offset(y: phase * (geometry.size.height + length) - length)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .clipped()
        }
    }
}

/// Drive motion with time rather than implicit animation transactions from the
/// surrounding List. Idle, inactive and Reduce Motion rows schedule no frames.
private struct AgentWorkMotion<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let working: Bool
    @ViewBuilder var content: (Double?) -> Content

    var body: some View {
        if working && !reduceMotion && scenePhase == .active {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
            }
        } else {
            content(nil)
        }
    }
}
