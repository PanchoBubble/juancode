import SwiftUI

/// Settings → Appearance pane (⌘,). The light/dark/system picker moved here off the
/// top-bar toolbar (juancode-v4ep) — it's a preference, not a per-session action, so
/// it belongs in the standard Settings window alongside Sessions and Shortcuts.
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Appearance").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Picker("Theme", selection: $model.themePreference) {
                    ForEach(ThemePreference.allCases) { pref in
                        Label(pref.label, systemImage: pref.symbol).tag(pref)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text("Follows the system setting, or lock the app to Light or Dark. juancode defaults to Dark so it blends into the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Spacer()
        }
        .frame(width: 520, height: 320)
    }
}
