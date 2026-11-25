import SwiftUI
import JuancodeCore

/// A parent chain's nested chains (juancode-8oa5.9), each drawn as one collapsed node:
/// its name, status and attention count. Clicking a node opens that chain. A child's
/// members stay in the child, so the parent's graph never draws them itself.
struct ChainSubchainNodes: View {
    @Environment(AppModel.self) private var model
    let children: [Chain]

    var body: some View {
        if !children.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(children) { child in
                        node(child, attention: model.chainAttention(child).total)
                    }
                }
            }
        }
    }

    private func node(_ child: Chain, attention: Int) -> some View {
        Button { model.openChain(slug: child.slug) } label: {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Label(child.isActive ? "Active" : "Closed",
                              systemImage: child.isActive ? "circle.fill" : "checkmark.circle")
                            .foregroundStyle(child.isActive ? Color.green : Color.secondary)
                        Text("\(child.members.count) member\(child.members.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        if attention > 0 {
                            Label("\(attention)", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.appPanel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.appDivider))
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("Open the nested chain \(child.name)")
        .accessibilityLabel("Nested chain \(child.name), \(child.isActive ? "active" : "closed"), \(attention) need attention")
        .accessibilityHint("Opens this chain")
    }
}
