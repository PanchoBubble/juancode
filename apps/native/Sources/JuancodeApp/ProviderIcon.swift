import AppKit
import JuancodeCore
import SwiftUI

struct ProviderIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private static let iconsBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Juancode_JuancodeApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    let provider: ProviderId
    var size: CGFloat = 12
    var tint: Color = .secondary
    var working: Bool = false

    private var label: String { Providers.spec(for: provider).label }
    private var image: NSImage? { Self.iconsBundle.image(forResource: provider.rawValue) }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .phaseAnimator(working && !reduceMotion && scenePhase == .active ? [false, true] : [false]) { icon, glowing in
                    icon
                        .scaleEffect(glowing ? 1.08 : 1)
                        .shadow(color: tint.opacity(glowing ? 0.65 : 0), radius: glowing ? 3 : 0)
                } animation: { _ in
                    .easeInOut(duration: 1.2)
                }
                .help(label)
                .accessibilityLabel(label)
        }
    }
}
