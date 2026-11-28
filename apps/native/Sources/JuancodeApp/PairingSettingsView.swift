// Settings → Phone pane (juancode-3aq8.3): a QR the iOS app scans to pair over
// Tailscale. It carries the two `tailscale serve` URLs (relay on 443, sidecar on
// 8443, as apps/native/README.md sets them up) and the pairing token.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import JuancodeServer

struct PairingSettingsView: View {
    /// This Mac's MagicDNS name, e.g. `mac.tail1234.ts.net`.
    @AppStorage("pairingTailnetHost") private var host = ""
    @State private var token: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phone").font(.headline)
            Text("Scan with the juancode iOS app. Anyone with this code can drive your terminals over your tailnet.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Tailscale host (mac.tailnet.ts.net)", text: $host)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let token, !host.isEmpty, let qr = Self.qrImage(Self.payload(host: host, token: token)) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
            }
            Spacer()
        }
        .padding()
        .frame(width: 480)
        .task {
            do { token = try RemoteAuth.loadOrCreateToken() } catch { self.error = "No pairing token: \(error)" }
            if host.isEmpty { host = Self.tailnetHost() ?? "" }
        }
    }

    static func payload(host: String, token: String) -> String {
        var comps = URLComponents(string: "juancode://pair")!
        comps.queryItems = [
            .init(name: "server", value: "https://\(host)"),
            .init(name: "oracle", value: "https://\(host):8443"),
            .init(name: "token", value: token),
        ]
        return comps.string ?? ""
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let out = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// `Self.DNSName` from `tailscale status --json`, or nil when the CLI is absent.
    static func tailnetHost() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                          "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = obj["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
