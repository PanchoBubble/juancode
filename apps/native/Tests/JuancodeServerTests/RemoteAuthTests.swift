import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import HTTPTypes
@testable import JuancodeServer

/// A remote client (one that came through `tailscale serve`) is refused without the
/// pairing token; a loopback client still needs none (juancode-3aq8.3).
/// Swift Testing so it runs without XCTest.
@Suite struct RemoteAuthTests {
    private func app() -> some ApplicationProtocol {
        let router = Router()
        router.add(middleware: RemoteAuth.Middleware(token: "secret", bindHost: "127.0.0.1"))
        router.get("/ping") { _, _ in "ok" }
        return Application(router: router)
    }

    private func status(_ headers: HTTPFields, uri: String = "/ping") async throws -> HTTPResponse.Status {
        try await app().test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: headers) { $0.status }
        }
    }

    @Test func remoteNeedsTheRightToken() async throws {
        let proxied: HTTPFields = [HTTPField.Name("X-Forwarded-For")!: "100.64.0.2"]
        #expect(try await status(proxied) == .unauthorized)

        var wrong = proxied
        wrong[.authorization] = "Bearer nope"
        #expect(try await status(wrong) == .unauthorized)

        var right = proxied
        right[.authorization] = "Bearer secret"
        #expect(try await status(right) == .ok)
        #expect(try await status(proxied, uri: "/ping?token=secret") == .ok)
    }

    @Test func loopbackNeedsNoToken() async throws {
        #expect(try await status([:]) == .ok)
    }
}
