import XCTest
import JuancodeCore
@testable import JuancodeServer

/// The two frames the `/ws` relay answers itself (juancode-tnxx).
///
/// A global pause is the one thing on that wire that is neither the daemon's to
/// answer nor a read off the desktop's mirror: the daemon has no frame for it, and
/// no row that separates "the pause slept this" from the four other producers of
/// `dormant`. So `pauseAll`/`resumeAll` stop at the relay, run through the same book
/// and driver the desktop's own button uses, and the capability list a client
/// feature-detects on has to say the endpoint speaks them.
///
/// Tested through the relay's decision functions rather than over real sockets. The
/// socket-level relay tests live next door in `CoreProxyServerTests`; what is
/// asserted here is every branch those pumps take, which is the part that is easy to
/// get wrong and hard to read off a live transcript.
final class CoreProxyGlobalPauseTests: XCTestCase {

    private final class SpyDriver: GlobalPauseDriver, @unchecked Sendable {
        @discardableResult func pauseAll() async -> Int { 0 }
        func resumeAll() async {}
    }

    private func served(_ book: GlobalPauseBook?) -> Bool {
        CoreProxyServer.servedPause(book) != nil
    }

    // MARK: - What the relay is willing to serve

    func testABookWithADriverIsServed() {
        let book = GlobalPauseBook(storage: .memory())
        book.driver = SpyDriver()
        XCTAssertTrue(served(book))
    }

    /// The discipline from the first half of this ticket, applied to the second: a
    /// capability nothing implements is worse than an absent one, because a client
    /// stops guarding the affordance on the strength of that string.
    func testABookWithNoDriverIsNotServed() {
        XCTAssertFalse(served(GlobalPauseBook(storage: .memory())),
                       "a headless relay with nothing to run the pause must not claim it can")
        XCTAssertFalse(served(nil))
    }

    // MARK: - The handshake the client actually reads

    func testTheDaemonsOwnCapabilitiesSurviveAndOneIsAdded() throws {
        let out = try XCTUnwrap(CoreProxyServer.withGlobalPauseAdvertised(
            #"{"type":"serverInfo","protocolVersion":1,"capabilities":["screen","stuck"],"clientId":"c1"}"#))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["capabilities"] as? [String], ["screen", "stuck", "globalPause"])
        // Rebuilt from the parsed object, so a daemon that grows a field keeps it.
        XCTAssertEqual(obj["clientId"] as? String, "c1")
        XCTAssertEqual(obj["protocolVersion"] as? Int, 1)
    }

    func testNothingElseOnTheWireIsRewritten() {
        XCTAssertNil(CoreProxyServer.withGlobalPauseAdvertised(
            #"{"type":"activity","sessionId":"s1","state":"idle","notify":false}"#))
        XCTAssertNil(CoreProxyServer.withGlobalPauseAdvertised("not json at all"))
    }

    /// The day the daemon grows its own global pause, the relay must stop adding a
    /// second copy of the string rather than advertise it twice.
    func testACapabilityTheDaemonAlreadyAdvertisesIsLeftAlone() {
        XCTAssertNil(CoreProxyServer.withGlobalPauseAdvertised(
            #"{"type":"serverInfo","protocolVersion":1,"capabilities":["globalPause"]}"#))
    }

    // MARK: - Which frames stop here

    func testTheTwoFramesAreRecognisedAndEverythingElseIsNot() {
        XCTAssertEqual(CoreProxyServer.frameType(#"{"type":"pauseAll"}"#), "pauseAll")
        XCTAssertEqual(CoreProxyServer.frameType(#"{"type":"resumeAll"}"#), "resumeAll")
        XCTAssertEqual(CoreProxyServer.frameType(#"{"type":"input","sessionId":"s1"}"#), "input")
        XCTAssertNil(CoreProxyServer.frameType("{oops"),
                     "a frame we cannot read is the daemon's to reject, not ours to swallow")
    }

    func testThePublishedFrameIsTheSameOneTheSwiftCoreSends() throws {
        let out = CoreProxyServer.pauseStateFrame(["b", "a"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "pauseState")
        XCTAssertEqual(obj["paused"] as? [String], ["a", "b"])
    }
}
