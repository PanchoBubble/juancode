import Testing
import Foundation
@testable import JuancodeCore

/// Layout-transition gate (juancode-1th.2): panel toggles mark a transition so
/// the terminal coordinators hold intermediate grid pushes and settle once.
@Suite struct LayoutTransitionGateTests {
    @Test func inactiveByDefault() {
        #expect(LayoutTransitionGate().active == false)
    }

    @Test func activeWithinTheWindow() {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(500))
        #expect(g.active == true)
    }

    @Test func expiresAfterTheWindow() async throws {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(90))
        #expect(g.active == false)
    }

    @Test func laterBeginNeverShortensTheWindow() {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(400))
        let long = g.windowEnd
        // A nested shorter transition (e.g. a divider commit during a fullscreen
        // animation) must not cut the longer window short. Asserted on the window
        // itself: sleeping past the short one and checking `active` measured the
        // right thing only while the sleep stayed inside the long window, and under
        // a loaded suite a 60ms sleep can outrun 400ms, so the gate had legitimately
        // expired and the test failed for the machine, not for the gate.
        g.begin(for: .milliseconds(10))
        #expect(g.windowEnd == long)
        #expect(g.active == true)
    }
}
