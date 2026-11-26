import JuancodeCore
import SwiftUI

/// An unobtrusive "review the agent's changes" nudge in the session top bar once the
/// agent settles a turn with unreviewed changes in a dirty tree. Clicking it (or the
/// sidebar badge, or ⌥⌘C) opens the Changes panel on the working tree. It lives in
/// the bar, not over the terminal, so it never covers the CLI's own last line.
struct ChangeReviewBanner: View {
    let counts: DiffCounts
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                DiffStatLabel(counts: counts, size: 11, weight: .semibold)
                Text("Review")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("The agent finished with changes — click to review (⌥⌘C)")
    }
}
