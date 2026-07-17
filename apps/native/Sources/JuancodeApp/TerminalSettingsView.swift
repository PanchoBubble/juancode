// Settings → Terminal pane: renderer choice + selection behaviour. Surfaced via
// the standard ⌘, window. The Metal toggle (juancode-epmq) applies live to every
// open pane — no restart — through `TerminalRenderer.didChange`.

import SwiftUI

struct TerminalSettingsView: View {
    @State private var metal = TerminalRenderer.shared.metalEnabled
    @State private var copyOnSelect = UserDefaults.standard
        .object(forKey: "terminal.copyOnSelect") as? Bool ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminal").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("GPU rendering (Metal, experimental)", isOn: $metal)
                    .onChange(of: metal) { _, on in
                        TerminalRenderer.shared.setMetalEnabled(on)
                    }
                Text("Draws terminal text on the GPU instead of CoreText — much "
                    + "lower CPU while agents stream output. Experimental: if you "
                    + "see rendering artifacts, switch it back off (applies "
                    + "instantly, no restart).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 4)

                Toggle("Copy on select", isOn: $copyOnSelect)
                    .onChange(of: copyOnSelect) { _, on in
                        UserDefaults.standard.set(on, forKey: "terminal.copyOnSelect")
                    }
                Text("Selecting text in a terminal copies it to the clipboard "
                    + "automatically, iTerm-style.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Spacer()
        }
        .frame(width: 520, height: 560)
    }
}
