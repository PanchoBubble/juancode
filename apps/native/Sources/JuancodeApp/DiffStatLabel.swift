import JuancodeCore
import SwiftUI

/// The one way a diff's size is written in this app: a yellow file count behind a
/// document glyph, then green additions and red deletions. Used for the working
/// tree (the review badge and banner) and for a session's pull request, so the two
/// read as the same measurement of the same thing at different stages.
///
/// Counts are abbreviated (`1.2k`, `3.4M`) — a sidebar row has no room for six
/// digits, and "how big" is the question, not "exactly how many".
struct DiffStatLabel: View {
    let counts: DiffCounts
    /// Point size of the numbers; the glyph rides two points smaller.
    var size: CGFloat = 10
    /// Weight of the numbers — the banner sits over a terminal and needs semibold.
    var weight: Font.Weight = .medium

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                Image(systemName: "doc.text").font(.system(size: size - 2))
                Text(compactCount(counts.files))
            }
            .foregroundStyle(Color(nsColor: .systemYellow))
            Text("+\(compactCount(counts.additions))")
                .foregroundStyle(Color(nsColor: .systemGreen))
            // The real minus sign, matching `ChangeStat.summary`.
            Text("−\(compactCount(counts.deletions))")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .font(.system(size: size, weight: weight).monospacedDigit())
    }
}
