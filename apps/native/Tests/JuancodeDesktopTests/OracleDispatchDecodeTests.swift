import Foundation
import Testing
@testable import JuancodeDesktop

/// Swift Testing so it runs without XCTest.
@Suite struct OracleDispatchDecodeTests {
    /// A line queued while the app was away still names who dispatched it and the role it
    /// was given (juancode-i831); dropping them started a loop child unlabelled and unchained.
    @Test func queuedLineKeepsRoleAndDispatchingSession() throws {
        let line = #"{"project":"/p","prompt":"x","dispatchId":"d","fromSessionId":"s-1","role":"tester"}"#
        let d = try JSONDecoder().decode(OracleDispatch.self, from: Data(line.utf8))
        #expect(d.fromSessionId == "s-1")
        #expect(d.role == "tester")
    }
}
