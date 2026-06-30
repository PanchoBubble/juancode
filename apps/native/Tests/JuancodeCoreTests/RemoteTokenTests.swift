import XCTest
@testable import JuancodeCore

/// Coverage for the remote-access token + bind-host config (juancode-u34.8).
/// These drive a dedicated data dir via `JUANCODE_DATA_DIR` so the persisted token
/// file lands in a temp dir, and clear `JUANCODE_TOKEN`/`JUANCODE_HOST` so the host
/// environment doesn't leak in.
final class RemoteTokenTests: XCTestCase {
    private var tempDir: String!
    private var savedToken: String??
    private var savedHost: String??
    private var savedDataDir: String??

    override func setUpWithError() throws {
        savedToken = ProcessInfo.processInfo.environment["JUANCODE_TOKEN"]
        savedHost = ProcessInfo.processInfo.environment["JUANCODE_HOST"]
        savedDataDir = ProcessInfo.processInfo.environment["JUANCODE_DATA_DIR"]
        tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        setenv("JUANCODE_DATA_DIR", tempDir, 1)
        unsetenv("JUANCODE_TOKEN")
        unsetenv("JUANCODE_HOST")
    }

    override func tearDownWithError() throws {
        restore("JUANCODE_TOKEN", savedToken)
        restore("JUANCODE_HOST", savedHost)
        restore("JUANCODE_DATA_DIR", savedDataDir)
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func restore(_ key: String, _ saved: String??) {
        if let saved, let value = saved { setenv(key, value, 1) } else { unsetenv(key) }
    }

    func testBindHostDefaultsToLoopback() {
        XCTAssertEqual(Config.bindHost, "127.0.0.1")
        setenv("JUANCODE_HOST", "0.0.0.0", 1)
        XCTAssertEqual(Config.bindHost, "0.0.0.0")
        setenv("JUANCODE_HOST", "  ", 1) // whitespace falls back to loopback
        XCTAssertEqual(Config.bindHost, "127.0.0.1")
    }

    func testRemoteTokenEmptyByDefault() {
        XCTAssertEqual(Config.remoteToken, "")
    }

    func testEnvTokenWins() {
        setenv("JUANCODE_TOKEN", "from-env", 1)
        XCTAssertEqual(Config.remoteToken, "from-env")
        // ensureRemoteToken returns the env token and does NOT persist a file.
        XCTAssertEqual(Config.ensureRemoteToken(), "from-env")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.remoteTokenPath))
    }

    func testEnsureGeneratesPersistsAndIsStable() {
        XCTAssertEqual(Config.remoteToken, "")
        let token = Config.ensureRemoteToken()
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Config.remoteTokenPath))
        // Now resolvable and stable across calls.
        XCTAssertEqual(Config.remoteToken, token)
        XCTAssertEqual(Config.ensureRemoteToken(), token)
    }

    func testGeneratedTokenIsUrlSafe() {
        let token = Config.ensureRemoteToken()
        // URL-safe base64 (no +, /, =) so it rides a ?token= query and Bearer header.
        XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertFalse(token.isEmpty)
    }
}
