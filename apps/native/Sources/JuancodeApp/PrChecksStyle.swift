// One vocabulary for a PR's CI state, shared by every row that draws it.
//
// The dot, the glyph and the "4/11" were copied into each PR row as it was written
// — the folder row, the queue row, the session capsule — so a fourth row could have
// invented a fourth green. There is one mapping now, and rows differ only in size.

import SwiftUI
import JuancodeCore

extension PrChecks {
    /// The colour the dot, glyph and fraction all paint in.
    var color: Color {
        switch self {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        case .none: return .secondary
        }
    }

    /// Status-adaptive glyph paired with the fraction; colour comes from `color`.
    var icon: String {
        switch self {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .none: return "minus.circle"
        }
    }
}

extension PullRequest {
    /// The check summary shown in a row: "passed/total" (e.g. "4/11"), or "No
    /// checks" when there are none.
    var checksText: String {
        checkCount == 0 ? "No checks" : "\(passedCount)/\(checkCount)"
    }
}

extension View {
    /// A notification-style count pinned to this view's top-right corner — the red
    /// "3" on a failing checks dot, the orange one on the comments bubble. It is an
    /// overlay, offset half its size out, so it never widens the row it sits in;
    /// zero or less draws nothing.
    func cornerCount(_ n: Int, color: Color) -> some View {
        overlay(alignment: .topTrailing) {
            if n > 0 {
                Text(verbatim: n > 99 ? "99+" : "\(n)")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(color, in: Capsule())
                    .fixedSize()
                    .alignmentGuide(.top) { $0.height / 2 }
                    .alignmentGuide(.trailing) { $0.width / 2 }
                    .allowsHitTesting(false)
            }
        }
    }
}
