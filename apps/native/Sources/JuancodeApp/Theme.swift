import SwiftUI
import AppKit

/// The user's appearance choice (juancode light/dark toggle). Persisted in `AppModel`
/// and applied to both layers: the SwiftUI content tree via `preferredColorScheme`
/// and the AppKit window chrome (title bar, menus, scrollers) via `NSApp.appearance`.
/// Defaults to `.dark` to preserve the app's long-standing pure-black look.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// UserDefaults key shared by `AppModel` (live changes) and `AppDelegate` (launch).
    static let defaultsKey = "juancode.appearance"

    /// The persisted preference, defaulting to `.dark` when unset or unrecognised.
    static var persisted: ThemePreference {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(ThemePreference.init(rawValue:)) ?? .dark
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// SwiftUI scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// AppKit appearance for the window chrome, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The next choice when cycling (the toolbar button's primary click).
    var next: ThemePreference {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension NSColor {
    /// A color that resolves differently in light vs dark appearances. Resolved lazily
    /// per the view/window's effective appearance, so it tracks runtime theme changes.
    static func appAdaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Window/terminal-matching backdrop: pure black in dark, near-white in light.
    /// Used for the `NSWindow` background so the chrome blends into the content.
    static let appWindow = appAdaptive(
        light: NSColor(calibratedWhite: 0.97, alpha: 1),
        dark: .black)
}

extension Color {
    /// Deep surface matching the window/terminal backdrop (was `Color.black`):
    /// pure black in dark, near-white in light.
    static let appSurface = Color(nsColor: .appWindow)

    /// A raised panel fill (was `Color(white: 0.07)`): dark charcoal in dark, a clean
    /// card white in light.
    static let appPanel = Color(nsColor: .appAdaptive(
        light: NSColor(calibratedWhite: 1.0, alpha: 1),
        dark: NSColor(calibratedWhite: 0.07, alpha: 1)))

    /// A slightly more elevated panel fill (was `Color(white: 0.10)`).
    static let appPanelElevated = Color(nsColor: .appAdaptive(
        light: NSColor(calibratedWhite: 0.93, alpha: 1),
        dark: NSColor(calibratedWhite: 0.10, alpha: 1)))

    /// A solid hairline for dividers and separators. Solid rather than a translucent
    /// white, which went muddy over the raised fills.
    static let appDivider = Color(nsColor: .appAdaptive(
        light: NSColor(calibratedWhite: 0.90, alpha: 1),
        dark: NSColor(calibratedWhite: 0.10, alpha: 1)))

    /// A band a step off the surface, for section/project headers.
    static let appBand = Color(nsColor: .appAdaptive(
        light: NSColor(calibratedWhite: 0.95, alpha: 1),
        dark: NSColor(calibratedWhite: 0.05, alpha: 1)))

    /// Fill behind a selected row; pairs with an `accentColor` leading bar.
    static let appSelection = Color.accentColor.opacity(0.16)

    /// A faint contrast tint that was `Color.white.opacity(x)` on dark — flips to black
    /// on light so hairlines and subtle fills stay visible in both appearances.
    static func appHairline(_ opacity: Double) -> Color {
        Color(nsColor: .appAdaptive(
            light: NSColor(calibratedWhite: 0, alpha: opacity),
            dark: NSColor(calibratedWhite: 1, alpha: opacity)))
    }
}
