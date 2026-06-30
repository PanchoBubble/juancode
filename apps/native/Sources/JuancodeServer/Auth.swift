import Foundation
import Hummingbird
import HTTPTypes

/// Opt-in token auth for the embedded server's remote/mobile access, mirroring the
/// Node server's `apps/server/src/auth.ts` contract so the existing web client
/// (`apps/web/src/lib/auth.ts`) works unchanged against the native backend.
///
/// When the configured token is empty, auth is a complete no-op — behaviour is
/// identical to plain localhost usage, so local development stays frictionless.
/// When set, every HTTP request and WebSocket upgrade must carry the matching
/// token, accepted three ways (most → least convenient for a browser), matching
/// the web client:
///   1. an httpOnly `juancode_token` cookie (set after the first authenticated load)
///   2. a `?token=<token>` query param (works for WS and bookmarks)
///   3. an `Authorization: Bearer <token>` header
///
/// Why no loopback exemption: the local SwiftTerm terminal is an *in-process*
/// subscriber to the session registry — it never touches HTTP/WS — so enabling auth
/// can never lock the user out of their own desktop terminal, and there is no local
/// network client to exempt. Crucially, a Cloudflare Tunnel forwards requests from a
/// same-machine `cloudflared`, so the peer address of tunneled (i.e. genuinely
/// remote) traffic *is* loopback; exempting loopback would silently disable auth
/// behind the tunnel. So when auth is on, the token is required unconditionally —
/// exactly as the Node server does.
///
/// The token is the ONLY thing between the public internet and a shell — pair it
/// with a tunnel and treat it like a password.
public struct AuthConfig: Sendable {
    /// The configured shared secret. Empty ⇒ auth disabled.
    public let token: String

    public init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Auth is only enforced when a non-empty token is configured.
    public var isEnabled: Bool { !token.isEmpty }

    public static let disabled = AuthConfig(token: "")

    /// Constant-time comparison of `candidate` against the configured token, so a
    /// wrong guess can't be distinguished from a near-match by timing. Returns false
    /// on length mismatch (without an early-out that would leak the length).
    public func tokenMatches(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        let a = Array(candidate.utf8)
        let b = Array(token.utf8)
        // XOR-accumulate over the longer of the two so the loop count never depends
        // on a length match; fold any length difference into the result.
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let n = max(a.count, b.count)
        var i = 0
        while i < n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
            i += 1
        }
        return diff == 0
    }
}

/// Name of the httpOnly cookie used to carry the token after the first authenticated
/// load. Mirrors `COOKIE_NAME` in the Node `auth.ts`.
let authCookieName = "juancode_token"

/// Extract a candidate token from the Authorization header, `?token=` query param,
/// or the `juancode_token` cookie (in that order). Mirrors `extractToken` in auth.ts.
func extractToken(from request: Request) -> String? {
    if let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") {
        let v = String(auth.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { return v }
    }
    if let q = request.uri.queryParameters["token"].map(String.init), !q.isEmpty {
        return q
    }
    if let cookie = request.headers[.cookie], let v = parseCookie(cookie, name: authCookieName) {
        return v
    }
    return nil
}

/// Minimal `Cookie:` header parser (avoids any cookie dependency). Mirrors auth.ts.
func parseCookie(_ header: String, name: String) -> String? {
    for part in header.split(separator: ";") {
        guard let eq = part.firstIndex(of: "=") else { continue }
        let key = part[part.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        if key == name {
            let raw = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return raw.removingPercentEncoding ?? raw
        }
    }
    return nil
}

private let cookieMaxAgeSeconds = 30 * 24 * 60 * 60

/// Serialize the auth cookie so subsequent same-origin requests + the WS upgrade
/// carry the token without re-passing `?token=`. `secure` is set behind TLS (a
/// tunnel terminates HTTPS, so the upstream `x-forwarded-proto` header drives it).
func authCookieHeader(value: String, secure: Bool) -> String {
    var parts = [
        "\(authCookieName)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)",
        "HttpOnly",
        "Path=/",
        "SameSite=Lax",
        "Max-Age=\(cookieMaxAgeSeconds)",
    ]
    if secure { parts.append("Secure") }
    return parts.joined(separator: "; ")
}

/// Whether the request arrived over TLS via a tunnel that set `x-forwarded-proto:
/// https` (Cloudflare Tunnel does), so the cookie can be marked `Secure`.
func isSecureRequest(_ request: Request) -> Bool {
    guard let name = HTTPField.Name("x-forwarded-proto") else { return false }
    return request.headers[name] == "https"
}

/// HTTP middleware enforcing token auth. Pass-through when auth is disabled.
/// Otherwise rejects unauthorized requests with 401 (a login page for browser
/// navigations, JSON for API/XHR). When a valid token arrives via query/header it
/// (re)sets the httpOnly cookie. Mirrors `authMiddleware` in auth.ts.
struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let config: AuthConfig

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard config.isEnabled else { return try await next(request, context) }

        let candidate = extractToken(from: request)
        guard config.tokenMatches(candidate) else {
            let accept = request.headers[.accept] ?? ""
            if request.method == .get, accept.contains("text/html") {
                var headers = HTTPFields()
                headers[.contentType] = "text/html; charset=utf-8"
                return Response(status: .unauthorized, headers: headers,
                                body: .init(byteBuffer: .init(string: loginPage)))
            }
            return jsonResponse(UnauthorizedBody(), status: .unauthorized)
        }

        var response = try await next(request, context)
        // Persist the token as a cookie when it came in via query/header so the SPA
        // and WS work after the first authenticated load without re-passing ?token=.
        let fromCookie = request.headers[.cookie].flatMap { parseCookie($0, name: authCookieName) }
        if !config.tokenMatches(fromCookie), let tok = candidate {
            response.headers[.setCookie] = authCookieHeader(value: tok, secure: isSecureRequest(request))
        }
        return response
    }
}

/// 401 JSON body for API/XHR callers. Mirrors `{ error, authRequired }` in auth.ts.
private struct UnauthorizedBody: Encodable {
    let error = "unauthorized"
    let authRequired = true
}

/// Gate a WebSocket upgrade on the token. Returns true when the upgrade may
/// proceed: auth disabled, or a valid token (Bearer/query/cookie). Mirrors
/// `verifyWsUpgrade` in auth.ts.
func authorizeWsUpgrade(_ request: Request, config: AuthConfig) -> Bool {
    if !config.isEnabled { return true }
    return config.tokenMatches(extractToken(from: request))
}

/// Minimal self-contained sign-in page served to unauthorized browser navigations.
/// Mirrors `loginPage()` in auth.ts.
let loginPage = """
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>juancode — sign in</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
    font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background:#0b0d10; color:#e5e5e5; }
  form { width:min(92vw,22rem); display:flex; flex-direction:column; gap:.75rem; padding:1.5rem;
    border:1px solid #262626; border-radius:.75rem; background:#0a0a0a; }
  h1 { margin:0; font-size:1rem; font-weight:600; }
  p { margin:0; font-size:.8rem; color:#a3a3a3; }
  input { padding:.6rem .7rem; border-radius:.5rem; border:1px solid #404040; background:#171717;
    color:#fafafa; font-size:1rem; }
  button { padding:.6rem .7rem; border-radius:.5rem; border:0; background:#404040; color:#fafafa;
    font-size:.9rem; font-weight:600; cursor:pointer; }
  button:hover { background:#525252; }
</style></head><body>
<form onsubmit="event.preventDefault();var t=encodeURIComponent(this.token.value.trim());if(t)location.href='/?token='+t;">
  <h1>juancode</h1>
  <p>Enter your access token to continue.</p>
  <input name="token" type="password" autocomplete="current-password" autofocus placeholder="Access token" />
  <button type="submit">Sign in</button>
</form></body></html>
"""
