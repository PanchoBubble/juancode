import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import JuancodeCore
import JuancodePersistence
@testable import JuancodeServer

/// Token-auth coverage for the embedded server (juancode-u34.8), mirroring the
/// Node server's `apps/server/src/auth.test.ts` so the native backend honours the
/// same contract as the existing web client (`apps/web/src/lib/auth.ts`).
final class AuthTests: XCTestCase {
    // MARK: - AuthConfig

    func testDisabledWhenTokenEmpty() {
        XCTAssertFalse(AuthConfig(token: "").isEnabled)
        XCTAssertFalse(AuthConfig(token: "   ").isEnabled) // whitespace trims to empty
        XCTAssertFalse(AuthConfig.disabled.isEnabled)
        XCTAssertTrue(AuthConfig(token: "s3cret").isEnabled)
    }

    func testTokenMatchesConstantTimeSafeAcrossLengths() {
        let c = AuthConfig(token: "s3cret")
        XCTAssertTrue(c.tokenMatches("s3cret"))
        XCTAssertFalse(c.tokenMatches("s3crey"))            // same length, wrong
        XCTAssertFalse(c.tokenMatches("longer-wrong-token")) // longer
        XCTAssertFalse(c.tokenMatches("s3"))                 // shorter
        XCTAssertFalse(c.tokenMatches(""))
        XCTAssertFalse(c.tokenMatches(nil))
    }

    // MARK: - extractToken / authorizeWsUpgrade (pure)

    private func request(headers: [(HTTPField.Name, String)] = [], path: String = "/api/x") -> Request {
        var fields = HTTPFields()
        for (name, value) in headers { fields[name] = value }
        let head = HTTPRequest(method: .get, scheme: "http", authority: "h", path: path, headerFields: fields)
        return Request(head: head, body: .init(buffer: ByteBuffer()))
    }

    func testExtractTokenFromBearerHeader() {
        XCTAssertEqual(extractToken(from: request(headers: [(.authorization, "Bearer s3cret")])), "s3cret")
        XCTAssertNil(extractToken(from: request(headers: [(.authorization, "Basic xyz")])))
    }

    func testExtractTokenFromQuery() {
        XCTAssertEqual(extractToken(from: request(path: "/ws?token=s3cret")), "s3cret")
        XCTAssertEqual(extractToken(from: request(path: "/ws?foo=1&token=abc")), "abc")
    }

    func testExtractTokenFromCookie() {
        XCTAssertEqual(extractToken(from: request(headers: [(.cookie, "foo=bar; juancode_token=s3cret")])), "s3cret")
        XCTAssertNil(extractToken(from: request(headers: [(.cookie, "foo=bar")])))
    }

    func testWsUpgradePassThroughWhenDisabled() {
        XCTAssertTrue(authorizeWsUpgrade(request(path: "/ws"), config: .disabled))
    }

    func testWsUpgradeGatedWhenEnabled() {
        let c = AuthConfig(token: "s3cret")
        XCTAssertFalse(authorizeWsUpgrade(request(path: "/ws"), config: c))
        XCTAssertFalse(authorizeWsUpgrade(request(path: "/ws?token=bad"), config: c))
        XCTAssertTrue(authorizeWsUpgrade(request(path: "/ws?token=s3cret"), config: c))
        XCTAssertTrue(authorizeWsUpgrade(request(headers: [(.authorization, "Bearer s3cret")], path: "/ws"), config: c))
    }

    // MARK: - HTTP middleware (end-to-end through the router)

    private func withServer(
        auth: AuthConfig,
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-auth-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) } }
        let state = try AppState(dbPath: dbPath)
        let app = Application(router: JuancodeServer.buildRouter(state: state, webDist: nil, auth: auth))
        try await app.test(.router) { client in try await body(client) }
    }

    func testDisabledLetsEverythingThrough() async throws {
        try await withServer(auth: .disabled) { client in
            try await client.execute(uri: "/api/health", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    func testEnabledRejectsMissingTokenWith401Json() async throws {
        try await withServer(auth: AuthConfig(token: "s3cret")) { client in
            try await client.execute(uri: "/api/health", method: .get,
                                     headers: [.accept: "application/json"]) { res in
                XCTAssertEqual(res.status, .unauthorized)
                let json = (try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))) as? [String: Any]
                XCTAssertEqual(json?["authRequired"] as? Bool, true)
            }
        }
    }

    func testEnabledServesLoginPageToBrowserNavigation() async throws {
        try await withServer(auth: AuthConfig(token: "s3cret")) { client in
            try await client.execute(uri: "/", method: .get, headers: [.accept: "text/html"]) { res in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertTrue(String(buffer: res.body).contains("Enter your access token"))
            }
        }
    }

    func testEnabledAcceptsTokenAndSetsCookie() async throws {
        try await withServer(auth: AuthConfig(token: "s3cret")) { client in
            try await client.execute(uri: "/api/health?token=s3cret", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                let cookie = res.headers[.setCookie] ?? ""
                XCTAssertTrue(cookie.contains("juancode_token=s3cret"))
                XCTAssertTrue(cookie.contains("HttpOnly"))
            }
            // Bearer header also works.
            try await client.execute(uri: "/api/health", method: .get,
                                     headers: [.authorization: "Bearer s3cret"]) { res in
                XCTAssertEqual(res.status, .ok)
            }
            // Wrong token is rejected.
            try await client.execute(uri: "/api/health?token=nope", method: .get,
                                     headers: [.accept: "application/json"]) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }
}
