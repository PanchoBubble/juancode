// Settings → Core, the core pill (shown in Settings and in the running-sessions
// popover's footer since it gave up its toolbar slot), and the launch-time "the
// rust core did not answer" offer.
//
// The picker is restart-scoped on purpose: a core owns the ptys, so switching one
// mid-flight would mean migrating live sessions between processes. It records a
// choice for the next launch and says so.

import SwiftUI
import AppKit
import JuancodeClient
import JuancodeCore

struct CoreSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choice = CoreBackendPreference.persisted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Core").font(.headline)
                Spacer()
                CoreBadgeLabel(selection: model.coreSelection,
                               connectionDown: model.coreConnectionDown)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Backend for the next launch", selection: $choice) {
                        ForEach(CoreBackend.allCases, id: \.self) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }
                    .disabled(model.coreSelection.isPinnedByEnvironment)
                    .onChange(of: choice) { _, picked in
                        CoreBackendPreference.setPersisted(picked)
                    }

                    if model.coreSelection.isPinnedByEnvironment {
                        Text("JUANCODE_CORE is set in this process's environment, so it "
                            + "wins over this picker for as long as it is set. This "
                            + "launch is on the \(model.coreSelection.active.rawValue) core.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if choice != model.coreSelection.active {
                        HStack(spacing: 8) {
                            Text("Takes effect on the next launch. Live sessions are never "
                                + "migrated between cores.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Quit juancode") { NSApp.terminate(nil) }
                                .controlSize(.small)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Each core keeps its own database, so **sessions started under one "
                        + "core are not listed under the other**. Two writers on one SQLite "
                        + "file, with two schemas drifting apart, is what that rule prevents.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 4)

                    detail("Active core", model.coreSelection.active.label)
                    detail("Wire protocol", "v\(model.core.info.protocolVersion)")
                    detail("Database", model.coreSelection.databasePath)
                    if model.coreSelection.active == .rust {
                        detail("Daemon", model.coreSelection.rustCoreURL)
                        detail("Daemon's own store",
                               "$JUANCODED_DATA_DIR/juancoded-rust.db (default ~/.juancode/rust-core)")
                        detail("Connection", model.coreConnectionDown.map { "down: \($0)" } ?? "up")
                        if let daemon = model.coreSelection.daemon {
                            detail("Daemon identity", daemon.summary)
                            if let exe = daemon.exePath { detail("Daemon binary", exe) }
                        } else {
                            detail("Daemon identity",
                                   "not reported — this daemon predates serverInfo.daemon")
                        }
                    }
                    if let persistence = model.coreSelection.sessionPersistence {
                        DaemonPersistenceRow(note: persistence)
                    }
                    ForEach(model.coreSelection.daemonWarnings) { warning in
                        BuildWarningRow(warning)
                    }
                    if let reason = model.coreSelection.unreachableReason {
                        detail("Fell back because", reason)
                    }

                    Divider().padding(.vertical, 4)

                    Text("Capabilities").font(.subheadline)
                    Text("From the core's `serverInfo` handshake. Anything missing is "
                        + "disabled in the UI with this reason, never silently dead.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(CoreCapability.allCases, id: \.self) { capability in
                        capabilityRow(capability)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
    }

    private func capabilityRow(_ capability: CoreCapability) -> some View {
        let has = model.supports(capability)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: has ? "checkmark.circle.fill" : "slash.circle")
                    .foregroundStyle(has ? .green : .orange)
                    .font(.system(size: 11))
                Text(capability.title).font(.system(size: 12, weight: has ? .regular : .medium))
                Text(capability.rawValue).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if !has {
                Text(capability.degradation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The active core, as a pill. Always shown, including for the default Swift core:
/// a screenshot in a bug report should never leave which core produced it open to
/// interpretation.
struct CoreBadgeLabel: View {
    let selection: CoreSelection
    let connectionDown: String?

    var body: some View {
        let down = connectionDown != nil
        // A stale daemon reads as "stale", not as "rust". The whole failure it comes
        // from is a UI that looked normal while mirroring a two-hour-old core, so it
        // has to be legible without opening anything.
        let stale = selection.daemonIsStale
        // And a daemon that outlives the app says so in the same place, because that
        // is the other thing you cannot see by looking at a session list: whether the
        // rows on screen are still there after Cmd-Q. `stale` wins the label when both
        // are true — the mode is never allowed to make an old core quieter — and the
        // tooltip carries both.
        let persists = selection.sessionPersistence
        let tint: Color = down ? .red : (stale ? .yellow : (selection.active == .rust ? .orange : .secondary))
        let label = stale ? "\(selection.active.rawValue) · stale"
            : (persists != nil ? "\(selection.active.rawValue) · persists" : selection.active.rawValue)
        return HStack(spacing: 4) {
            Image(systemName: down || stale ? "exclamationmark.triangle.fill"
                : (persists != nil ? "pin.fill" : "cpu"))
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .help(persists ?? "Quitting the app ends this core's live sessions.")
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(down ? 0.22 : 0.18)))
        .foregroundStyle(tint)
    }
}

/// That this core's sessions outlive the app, and what they are running on. Shared by
/// the badge popover and the Settings pane, and deliberately NOT a `BuildWarningRow`:
/// a stated mode doing what it was asked is not a fault, and rendering it in the yellow
/// that means "you are on an old core" would cost that colour its meaning. The two sit
/// beside each other when both apply, which is the case worth seeing.
struct DaemonPersistenceRow: View {
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(note)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One thing wrong with the build on screen — the daemon's or the app's own — spelled
/// out. Shared by the badge popover and the Settings pane so they can never disagree
/// about it.
struct BuildWarningRow: View {
    let headline: String
    let detail: String

    /// The daemon is running a build the checkout has moved past.
    init(_ warning: DaemonWarning) {
        self.headline = warning.headline
        self.detail = warning.detail
    }

    /// The APP is (juancode-b06m). Same row on purpose: to the reader these are one
    /// fact — what is on screen is not what the checkout would build — and splitting
    /// them across two designs would make the newer one look like a different class
    /// of problem than the one it is.
    init(_ warning: AppBuildWarning) {
        self.headline = warning.headline
        self.detail = warning.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.yellow)
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown once, at launch, when the rust core was selected and did not answer. The
/// app is already on the Swift core by then — this is where that is admitted, and
/// where the user chooses whether to accept it or go start the daemon.
struct CoreFallbackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The rust core did not answer").font(.headline)
            }
            Text(model.coreSelection.unreachableReason ?? "The daemon was not reachable.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Looked for it at \(model.coreSelection.rustCoreURL). This launch is running "
                + "on the Swift core instead, with its own database, so any session you "
                + "started under the rust core is not listed here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("`scripts/dev-daemon.sh agent install` keeps a daemon running across app "
                + "quits, logout and reboot, so this does not happen again. For one launch, "
                + "`scripts/dev-app.sh` starts one that lives as long as its terminal. Either "
                + "way, relaunch afterwards — the core is chosen once, at boot.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Switch the setting to Swift") {
                    CoreBackendPreference.setPersisted(.swift)
                    dismiss()
                }
                Spacer()
                Button("Quit and start the daemon") { NSApp.terminate(nil) }
                Button("Continue on Swift") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
    }
}
