import SwiftUI

/// Keep the provider icon and status rail on the same busy-state animation.
/// Animate only their paint, so terminal and row geometry remain stable.
struct AgentWorkPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let working: Bool
    let tint: Color
    var scale: CGFloat = 1

    private var animates: Bool { working && !reduceMotion && scenePhase == .active }

    func body(content: Content) -> some View {
        content.phaseAnimator(animates ? [false, true] : [false]) { indicator, glowing in
            indicator
                .opacity(animates && !glowing ? 0.4 : 1)
                .scaleEffect(glowing ? scale : 1)
                .shadow(color: tint.opacity(glowing ? 0.8 : 0), radius: glowing ? 4 : 0)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
    }
}
