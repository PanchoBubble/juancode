import SwiftUI
import JuancodeCore

/// "Restored from disk" banner (juancode-mya), shown top-leading over a terminal
/// pane that a cold app launch replayed from persisted scrollback. It explains an
/// otherwise frozen-looking wall of old output while the session auto-revives:
///
///   `.resuming`    — a spinner + "resuming conversation". `AppModel` auto-dismisses
///                    it on the first live pty byte or after a short grace, so it
///                    never sits over a working TUI. No manual control (it's about
///                    to vanish on its own).
///   `.unresumable` — the prior conversation couldn't be resumed; the pane stays
///                    replay-only, so this one carries an X to dismiss.
///
/// Placed top-leading so it stacks beside the top-trailing `RemoteDriveOverlay`
/// (juancode-2t4) rather than overlapping it. Keyed per session id by
/// `AppModel.restoredBanners`, so a session switch shows the new pane's banner (or
/// none) and never leaks the old one's.
struct SessionRestoredOverlay: View {
    let phase: SessionRestoredBanner.Phase
    let onDismiss: () -> Void

    private var isResuming: Bool { phase == .resuming }

    var body: some View {
        HStack(spacing: 6) {
            if isResuming {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(SessionRestoredBanner.title(for: phase))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if !isResuming {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .foregroundStyle(tint)
        .help(isResuming
              ? "This pane was restored from disk after a restart; the prior conversation is resuming."
              : "This pane was restored from disk; its prior conversation couldn't be resumed, so it shows replayed history.")
    }

    private var tint: Color { isResuming ? .cyan : .yellow }
}
