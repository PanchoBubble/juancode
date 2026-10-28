import SwiftUI
import JuancodeCore

struct PrStackBadge: View {
    let stack: PrStack

    var body: some View {
        let tint = ChainBadge.color(for: stack.id)
        Label("\(stack.numbers.count)", systemImage: "link")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .fixedSize()
            .help("Stack of \(stack.numbers.count) open PRs: " +
                  stack.numbers.map { "#\($0)" }.joined(separator: ", "))
            .accessibilityLabel("Stack of \(stack.numbers.count) open pull requests")
    }
}

