import Foundation
import Hummingbird
import HTTPTypes
import Security

/// Pairing token for remote clients (juancode-3aq8.3).
///
/// The phone reaches `:4280` through `tailscale serve`, which forwards to 127.0.0.1,
/// so the peer address alone cannot tell the phone from a local tool. A request is
/// remote when it carries a reverse proxy's headers, names a non-loopback Host, or
/// the server is bound off loopback; only those must present the token. Local
/// clients (the app, the sidecar, scripts) keep working without one.
/// Assumes HTTP-mode `tailscale serve` (which adds X-Forwarded-For); a raw
/// `--tcp` forward would look local, and the README says not to use one.
public enum RemoteAuth {
    /// `~/.juancode/remote-token`, shared with the sidecar (`remote-auth.ts`).
    public static var tokenPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".juancode/remote-token")
    }

    /// Read the token, minting it once if missing. `withoutOverwriting` makes a
    /// race with the sidecar's own mint resolve to whichever file landed first.
    public static func loadOrCreateToken(at path: String = tokenPath) throws -> String {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            return try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    static func isRemote(_ request: Request, bindHost: String) -> Bool {
        if !loopbackHosts.contains(bindHost) { return true }
        for field in request.headers {
            let name = field.name.canonicalName
            if name == "x-forwarded-for" || name == "forwarded" || name.hasPrefix("tailscale-") {
                return true
            }
        }
        if let authority = request.head.authority {
            let host = authority.hasPrefix("[")
                ? String(authority.prefix(through: authority.firstIndex(of: "]") ?? authority.startIndex))
                : String(authority.split(separator: ":", maxSplits: 1).first ?? "")
            if !loopbackHosts.contains(host.lowercased()) { return true }
        }
        return false
    }

    static func presentedToken(_ request: Request) -> String? {
        if let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") {
            return String(auth.dropFirst("Bearer ".count))
        }
        return request.uri.queryParameters.get("token")
    }

    /// Constant-time so a remote guesser learns nothing from timing.
    static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Rejects a remote request without the right token, on both the HTTP router
    /// and the WebSocket upgrade router.
    struct Middleware<Context: RequestContext>: RouterMiddleware {
        let token: String
        let bindHost: String

        func handle(_ request: Request, context: Context,
                    next: (Request, Context) async throws -> Response) async throws -> Response {
            if isRemote(request, bindHost: bindHost), !matches(presentedToken(request), token) {
                throw APIError(.unauthorized, "remote clients need the pairing token")
            }
            return try await next(request, context)
        }
    }
}
