// The toolbar's needs-you count (juancode-8oa5.14): how many chain_ask questions are
// waiting on you across every chain. One click opens the chain holding the oldest one,
// whose overview leads with its questions inbox.

import SwiftUI
import JuancodeCore

struct ChainQuestionsBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let questions = model.allOpenQuestions
        // Leftmost in the trailing group, so appearing at a first question shifts nothing.
        if let oldest = questions.first {
            let label = "\(questions.count) question\(questions.count == 1 ? "" : "s") for you"
            Button {
                model.openChain(slug: oldest.chainSlug)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.bubble.fill")
                    Text("\(questions.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(Color.orange)
            .help("\(label) — open the oldest")
            .accessibilityLabel(label)
            .accessibilityHint("Opens the chain with the oldest question")
            .clickCursor()
        }
    }
}
