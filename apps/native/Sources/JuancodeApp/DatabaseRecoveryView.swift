import SwiftUI
import AppKit

/// Shown at launch when the on-disk database couldn't be opened and the app fell
/// back to an ephemeral in-memory store (juancode-4zk). Explains the degraded
/// state and offers recovery: reset the corrupt file (moved aside as a backup) and
/// relaunch, or continue this session without saving. Replaces the old
/// `fatalError` that bricked the app on a corrupt DB.
struct DatabaseRecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(.orange)
                Text("Couldn't open the database").font(.title3).bold()
            }

            Text("juancode is running **without saving** this session — new sessions and history won't persist after you quit. Resetting starts a fresh database; your current file is kept as a timestamped backup.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let path = model.corruptDbPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Database").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let reason = model.degradedReason {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Error").font(.system(size: 10)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(reason).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                }
            }

            HStack {
                Button("Continue Without Saving") { dismiss() }
                    .keyboardShortcut(.cancelAction).clickCursor()
                Spacer()
                Button("Reset Database & Quit", role: .destructive) { resetAndQuit() }
                    .keyboardShortcut(.defaultAction).clickCursor()
            }
        }
        .padding(20).frame(width: 460)
    }

    private func resetAndQuit() {
        // Move the unopenable file aside (kept as a backup) so a fresh DB is created
        // on next launch, then quit — the user reopens juancode to start clean.
        if model.resetCorruptDatabase() != nil {
            NSApp.terminate(nil)
        } else {
            // Nothing to move aside (e.g. the data dir itself is unwritable) — the
            // error banner in AppModel surfaces why; leave the sheet up.
            dismiss()
        }
    }
}
