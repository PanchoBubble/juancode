import XCTest
@testable import JuancodeServices

/// Covers the pure health → presentation mapping (the Swift analogue of the web
/// `StatusPanel.tsx` `HEALTH` map) and the row's display-status fallback.
final class StatusPresentationTests: XCTestCase {
    func testEveryHealthMapsToExpectedPaletteAndLabel() {
        let expected: [(McpHealth, HealthPalette, String)] = [
            (.connected, .emerald, "Connected"),
            (.enabled, .emerald, "Enabled"),
            (.needsAuth, .amber, "Needs auth"),
            (.pending, .sky, "Pending approval"),
            (.failed, .red, "Failed"),
            (.disabled, .neutralStrong, "Disabled"),
            (.unknown, .neutral, "Unknown"),
        ]
        for (health, palette, label) in expected {
            let p = HealthPalette.presentation(for: health)
            XCTAssertEqual(p.palette, palette, "palette for \(health)")
            XCTAssertEqual(p.label, label, "label for \(health)")
        }
    }

    func testDisplayStatusPrefersRawLabelOverFallback() {
        let withLabel = McpServerStatus(
            name: "linear", detail: "https://mcp.linear.app/mcp", transport: "http",
            health: .needsAuth, statusLabel: "! Needs authentication", auth: nil)
        XCTAssertEqual(withLabel.displayStatus, "! Needs authentication")
    }

    func testDisplayStatusFallsBackToNormalizedLabelWhenEmpty() {
        let noLabel = McpServerStatus(
            name: "x", detail: "cmd", transport: "stdio",
            health: .connected, statusLabel: "", auth: nil)
        XCTAssertEqual(noLabel.displayStatus, "Connected")
    }

    func testServerPresentationIsDrivenByHealth() {
        let s = McpServerStatus(
            name: "x", detail: "cmd", transport: "stdio",
            health: .failed, statusLabel: "✗ Failed to connect", auth: nil)
        XCTAssertEqual(s.presentation.palette, .red)
    }
}
