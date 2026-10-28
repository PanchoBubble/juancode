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
        .help("PR \(stack.position(of: number) ?? 1) of \(stack.size) in stack — click to see the list")
        .accessibilityLabel("Stack position \(stack.position(of: number) ?? 1) of \(stack.size)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(stack.stackNumber.map { "PR stack #\($0)" } ?? "PR stack").font(.headline)
                Text("Base → tip · \(stack.size) PRs")
                    .font(.caption).foregroundStyle(.secondary)
                if stack.entries.count < stack.size {
                    Text("Some stack members are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(stack.entries, id: \.number) { pr in
                            if let url = URL(string: pr.url) {
                                Link(destination: url) {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(pr.position)").monospacedDigit()
                                            .foregroundStyle(tint).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("#\(pr.number) · \(pr.title)")
                                                .lineLimit(2)
                                            if pr.state != "OPEN" {
                                                Text(pr.state.lowercased()).font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
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
