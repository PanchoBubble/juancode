// Settings → Terminal pane: which surface, renderer choice, selection behaviour.
// Surfaced via the standard ⌘, window. Both the surface picker and the Metal toggle
// (juancode-epmq) apply live to every open pane — no restart.

import SwiftUI

struct TerminalSettingsView: View {
    @State private var ghostty = TerminalBackend.shared.useGhostty
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
                Toggle("Ghostty surface (experimental)", isOn: $ghostty)
                    .onChange(of: ghostty) { _, on in
                        TerminalBackend.shared.setUseGhostty(on)
                    }
                Text("Renders panes with libghostty (Ghostty's engine, always GPU) "
                    + "instead of SwiftTerm. Cleaner resize, and it owns its own "
                    + "frame pacing. Applies instantly: open panes swap surface and "
                    + "replay their scrollback. Experimental — on libghostty 1.2.x "
                    + "this could freeze the app when several panes attached at once; "
                    + "that was fixed upstream in 1.3.0, but if a pane ever wedges, "
                    + "switch back here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 4)

                Toggle("GPU rendering (Metal, experimental)", isOn: $metal)
                    .disabled(ghostty)
                    .onChange(of: metal) { _, on in
                        TerminalRenderer.shared.setMetalEnabled(on)
                    }
                Text(ghostty
                    ? "Only applies to the SwiftTerm surface. The Ghostty surface is "
                        + "GPU-rendered either way."
                    : "Draws terminal text on the GPU instead of CoreText — much "
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
