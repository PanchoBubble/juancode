import AppKit
import JuancodeCore
import SwiftUI

extension ProviderId {
    /// A distinct hue per agent so session rows can be told apart at a glance. Session
    /// status rides on the leading rail instead of the icon tint. Kept clear of the
    /// status vocabulary (orange = working, blue = idle, green = done) where possible.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: .primary  // white in dark mode, black in light: visible on both
        case .opencode: Color(red: 0.96, green: 0.45, blue: 0.71)
        case .kimi: Color(red: 0.09, green: 0.51, blue: 1.0)
        case .cursor: .primary
        case .antigravity: Color(red: 0.55, green: 0.36, blue: 0.96)
        }
    }
}

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
                .modifier(AgentWorkPulse(working: working))
                .help(label)
                .accessibilityLabel(label)
        }
    }
}
