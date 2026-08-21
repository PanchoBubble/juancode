// Settings → Core, plus the always-visible active-core badge in the window
// toolbar and the launch-time "the rust core did not answer" offer.
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
        return HStack(spacing: 4) {
            Image(systemName: down ? "exclamationmark.triangle.fill" : "cpu")
                .font(.system(size: 9))
            Text(selection.active.rawValue)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(down ? Color.red.opacity(0.22)
                      : (selection.active == .rust ? Color.orange.opacity(0.18)
                         : Color.secondary.opacity(0.14))))
        .foregroundStyle(down ? .red : (selection.active == .rust ? .orange : .secondary))
    }
}

/// Toolbar item: the badge, with the whole story behind a click.
struct CoreBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            CoreBadgeLabel(selection: model.coreSelection,
                           connectionDown: model.coreConnectionDown)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Active core: \(model.coreSelection.active.label)")
                    .font(.system(size: 12, weight: .semibold))
                if let down = model.coreConnectionDown {
                    Text("Connection down: \(down). Sessions keep running in the daemon; "
                        + "the app is retrying.")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = model.coreSelection.unreachableReason {
                    Text("Asked for the \(model.coreSelection.requested.rawValue) core and fell "
                        + "back: \(reason)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Wire protocol v\(model.core.info.protocolVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.coreSelection.databasePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                let missing = model.core.missingCapabilities
                if !missing.isEmpty {
                    Divider()
                    Text("Unavailable on this core: "
                        + missing.map(\.title).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Settings → Core lists what each one costs.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(width: 320)
        }
    }

    private var helpText: String {
        var parts = ["Active core: \(model.coreSelection.active.label)"]
        if let down = model.coreConnectionDown { parts.append("connection down: \(down)") }
        if let reason = model.coreSelection.unreachableReason { parts.append("fell back: \(reason)") }
        return parts.joined(separator: " · ")
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
            Text("Start the daemon with `cargo run -p juancoded` (or set JUANCODE_RUST_CORE_URL "
                + "to where it is listening), then relaunch.")
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
