import XCTest
@testable import JuancodePersistence
import JuancodeCore

/// `tracked_prs` table coverage (juancode-b4m): the payload-based `TrackedPrStore`
/// conformance backing `PrTrackingEngine`'s watch list. The list is written whole
/// (delete-all + insert in one transaction), so the interesting cases are the
/// replace semantics.
final class TrackedPrStoreTests: XCTestCase {
    private var path: String!
    private var store: GRDBStore!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() as NSString
        path = dir.appendingPathComponent("juancode-trackedprs-\(UUID().uuidString).db")
        store = try GRDBStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func testLoadFromEmptyTable() {
        XCTAssertTrue(store.loadTrackedPrPayloads().isEmpty)
    }

    func testRoundTrip() {
        let payloads = ["/repo#1": #"{"number":1}"#, "/repo#2": #"{"number":2}"#]
        store.replaceTrackedPrPayloads(payloads)
        XCTAssertEqual(store.loadTrackedPrPayloads(), payloads)
    }

    func testReplaceAllClearsRemovedIds() {
        store.replaceTrackedPrPayloads(["/repo#1": "a", "/repo#2": "b"])
        store.replaceTrackedPrPayloads(["/repo#2": "b2", "/repo#3": "c"])
        XCTAssertEqual(store.loadTrackedPrPayloads(), ["/repo#2": "b2", "/repo#3": "c"])
    }

    func testEmptyReplaceClearsTable() {
        store.replaceTrackedPrPayloads(["/repo#1": "a"])
        store.replaceTrackedPrPayloads([:])
        XCTAssertTrue(store.loadTrackedPrPayloads().isEmpty)
    }

    func testSurvivesReopen() throws {
        store.replaceTrackedPrPayloads(["/repo#1": "a"])
        store = nil
        store = try GRDBStore(path: path)
        XCTAssertEqual(store.loadTrackedPrPayloads(), ["/repo#1": "a"])
    }
}
