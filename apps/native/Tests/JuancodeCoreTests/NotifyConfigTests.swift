import XCTest
@testable import JuancodeCore

/// The app's half of notification routing after the POST moved to the daemon
/// (juancode-52e8.14.7): this process no longer sends anything, it only tells
/// `juancoded` where to send. The file shape here is the contract with
/// `juancoded-core/src/notify.rs`, which reads it on every notifying turn boundary.
final class NotifyConfigTests: XCTestCase {
    private var dir: String = ""
    private var path: String { (dir as NSString).appendingPathComponent("notify.json") }

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notify-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testRoundTripsTheUrl() {
        XCTAssertTrue(NotifyConfig.setWebhookURL("  https://hooks.example/x  ", at: path))
        XCTAssertEqual(NotifyConfig.webhookURL(at: path), "https://hooks.example/x")
    }

    /// The daemon reads this key by name; a rename here is a webhook that silently
    /// stops firing.
    func testTheFileShapeIsWhatTheDaemonReads() throws {
        NotifyConfig.setWebhookURL("https://hooks.example/x", at: path)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["webhookUrl"] as? String, "https://hooks.example/x")
    }

    func testClearingRemovesTheKeyRatherThanWritingAnEmptyOne() throws {
        NotifyConfig.setWebhookURL("https://hooks.example/x", at: path)
        NotifyConfig.setWebhookURL("", at: path)
        XCTAssertNil(NotifyConfig.webhookURL(at: path))
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["webhookUrl"])
    }

    /// A knob the daemon grows later must not be erased by somebody typing in the
    /// Settings field.
    func testOtherKeysSurviveAnEdit() throws {
        try #"{"webhookUrl":"https://old/x","somethingElse":7}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        NotifyConfig.setWebhookURL("https://new/x", at: path)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["webhookUrl"] as? String, "https://new/x")
        XCTAssertEqual(obj["somethingElse"] as? Int, 7)
    }

    func testAMissingOrMalformedFileIsNoWebhook() throws {
        XCTAssertNil(NotifyConfig.webhookURL(at: path))
        try "not json at all".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(NotifyConfig.webhookURL(at: path))
    }

    /// The default path is the DAEMON's store (`~/.juancode/rust-core`), not the Swift
    /// core's `~/.juancode/data`: the file belongs to the process that fires the POST.
    func testTheDefaultPathSitsBesideTheDaemonsStore() {
        let resolved = NotifyConfig.path
        XCTAssertTrue(resolved.hasSuffix("notify.json"), resolved)
        if ProcessInfo.processInfo.environment["JUANCODE_NOTIFY_CONFIG"] == nil,
           ProcessInfo.processInfo.environment["JUANCODED_DATA_DIR"] == nil,
           ProcessInfo.processInfo.environment["JUANCODE_DATA_DIR"] == nil {
            XCTAssertTrue(resolved.contains(".juancode/rust-core"), resolved)
        }
    }
}
