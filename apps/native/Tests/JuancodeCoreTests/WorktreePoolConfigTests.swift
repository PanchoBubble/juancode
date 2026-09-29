import XCTest
@testable import JuancodeCore

/// The file shape is the contract with `juancoded-core/src/worktree/pool.rs`.
final class WorktreePoolConfigTests: XCTestCase {
    private var dir: String = ""
    private var path: String { (dir as NSString).appendingPathComponent("worktree-pool.json") }

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("worktree-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testMissingFileIsTheDaemonsDefault() {
        XCTAssertEqual(WorktreePoolConfig.maxIdle(at: path), 20)
    }

    func testTheKeyIsWhatTheDaemonReadsAndOtherKeysSurvive() throws {
        try Data(#"{"other":1}"#.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(WorktreePoolConfig.setMaxIdle(0, at: path))
        XCTAssertEqual(WorktreePoolConfig.maxIdle(at: path), 0)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["maxIdlePerRepo"] as? Int, 0)
        XCTAssertEqual(obj["other"] as? Int, 1)
    }
}
