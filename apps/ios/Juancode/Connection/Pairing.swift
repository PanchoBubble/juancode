import Foundation
import Security

/// What the Mac's Settings → Phone QR carries:
/// `juancode://pair?server=…&oracle=…&token=…` (juancode-3aq8.3).
struct Pairing: Codable, Equatable {
    var server: URL
    var oracle: URL?
    var token: String

    init?(url: URL) {
        guard url.scheme == "juancode", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value.flatMap(URL.init(string:)),
              server.scheme == "https" || server.scheme == "http",
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        self.server = server
        self.oracle = items.first(where: { $0.name == "oracle" })?.value.flatMap(URL.init(string:))
        self.token = token
    }
}

/// The pairing lives in the Keychain: it holds the bearer token.
enum PairingStore {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.juanone.juancode.pairing",
        kSecAttrAccount as String: "default",
    ] }

    static func load() -> Pairing? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing) {
        clear()
        var q = query
        q[kSecValueData as String] = try? JSONEncoder().encode(pairing)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
