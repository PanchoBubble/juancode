import AppKit
import JuancodeCore
import SwiftUI

struct ProviderIcon: View {
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
                .modifier(AgentWorkPulse(working: working, tint: tint))
                .help(label)
                .accessibilityLabel(label)
        }
    }
}
