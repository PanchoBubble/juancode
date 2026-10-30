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

    private var label: String { Providers.spec(for: provider).label }

    var body: some View {
        Image(provider.rawValue, bundle: Self.iconsBundle)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}
