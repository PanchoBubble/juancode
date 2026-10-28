import SwiftUI
import JuancodeCore

struct PrStackBadge: View {
    let stack: PrStack
    let number: Int
    @Binding var showing: Bool

    var body: some View {
        let tint = ChainBadge.color(for: stack.id)
        Button { showing.toggle() } label: {
            Label("\(stack.position(of: number) ?? 1)", systemImage: "link")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(tint.opacity(0.16), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("PR \(stack.position(of: number) ?? 1) of \(stack.prs.count) in stack — click to see the list")
        .accessibilityLabel("Stack position \(stack.position(of: number) ?? 1) of \(stack.prs.count)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PR stack").font(.headline)
                Text("Base → tip · \(stack.prs.count) open PRs")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(stack.prs.enumerated()), id: \.element.number) { index, pr in
                            if let url = URL(string: pr.url) {
                                Link(destination: url) {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1)").monospacedDigit()
                                            .foregroundStyle(tint).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("#\(pr.number) · \(pr.title)")
                                                .lineLimit(2)
                                            Text(pr.branch).font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if pr.number == number {
                                            Image(systemName: "checkmark").foregroundStyle(tint)
                                        }
                                    }
                                    .font(.system(size: 12))
                                    .padding(6)
                                    .background(pr.number == number ? tint.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open #\(pr.number) on GitHub")
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            .padding(12)
            .frame(width: 380)
        }
    }
}
