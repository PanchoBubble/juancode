import SwiftUI

@main
struct JuancodeApp: App {
    @State private var core: RemoteCore? = PairingStore.load().map { RemoteCore(pairing: $0) }
    @AppStorage("lastSession") private var selected: String? // reopened on launch

    var body: some Scene {
        WindowGroup {
            Group {
                if let core {
                    RootView(core: core, selected: $selected, unpair: unpair)
                } else {
                    PairingView(onPaired: pair)
                }
            }
            .onOpenURL(perform: open)
        }
    }

    /// `juancode://pair?…` pairs; `juancode://session/<id>` opens a session.
    private func open(_ url: URL) {
        if let pairing = Pairing(url: url) {
            pair(pairing)
        } else if url.scheme == "juancode", url.host() == "session", let id = url.pathComponents.dropFirst().first {
            selected = id
        }
    }

    private func pair(_ pairing: Pairing) {
        PairingStore.save(pairing)
        core?.stop()
        core = RemoteCore(pairing: pairing)
    }

    private func unpair() {
        PairingStore.clear()
        core?.stop()
        core = nil
        selected = nil
    }
}
