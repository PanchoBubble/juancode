import SwiftUI

/// An unobtrusive "review the agent's changes" nudge floated over the bottom of a
/// session's terminal once the agent settles a turn with unreviewed changes in a
/// dirty tree. Clicking it (or the sidebar badge, or ⌘⇧C) opens the Changes panel on
/// the working tree. It floats as an overlay so it never reflows the pty grid — the
/// terminal render stays intact.
struct ChangeReviewBanner: View {
    let summary: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                Text("Review")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("The agent finished with changes — click to review (⌘⇧C)")
    }
}
