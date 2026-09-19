import Foundation

/// Pure presentation mapping for MCP health states — the Swift analogue of the
/// web `StatusPanel.tsx` `HEALTH` map. Lives in the services target (no SwiftUI
/// dependency) so it can be unit-tested directly; the SwiftUI view maps the
/// `dot` palette name to a concrete `Color`.
public enum HealthPalette: String, Sendable, Equatable {
    case emerald
    case amber
    case sky
    case red
    case neutralStrong  // dimmer grey for "disabled"
    case neutral

    /// Human-readable fallback label + dot/text palette for an `McpHealth`,
    /// mirroring the web `HEALTH` record exactly.
    public static func presentation(for health: McpHealth) -> HealthPresentation {
        switch health {
        case .connected: return HealthPresentation(palette: .emerald, label: "Connected")
        case .enabled: return HealthPresentation(palette: .emerald, label: "Enabled")
        case .needsAuth: return HealthPresentation(palette: .amber, label: "Needs auth")
        case .pending: return HealthPresentation(palette: .sky, label: "Pending approval")
        case .failed: return HealthPresentation(palette: .red, label: "Failed")
        case .disabled: return HealthPresentation(palette: .neutralStrong, label: "Disabled")
        case .unknown: return HealthPresentation(palette: .neutral, label: "Unknown")
        }
    }
}

/// The dot/text color palette + default label for one health state.
public struct HealthPresentation: Sendable, Equatable {
    public let palette: HealthPalette
    public let label: String

    public init(palette: HealthPalette, label: String) {
        self.palette = palette
        self.label = label
    }
}

public extension McpServerStatus {
    /// The presentation (dot palette + label) for this server's health.
    var presentation: HealthPresentation { HealthPalette.presentation(for: health) }

    /// What the row shows as its trailing status text: the CLI's raw label when
    /// present, else the normalized fallback label. Mirrors `s.statusLabel || h.label`.
    var displayStatus: String {
        statusLabel.isEmpty ? presentation.label : statusLabel
    }
}
