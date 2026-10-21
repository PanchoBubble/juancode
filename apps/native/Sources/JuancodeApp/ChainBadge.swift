import SwiftUI
import JuancodeCore

/// The chain an item is in, as a pill: the slug in the chain's own color, drawn on
/// every row that can be a member (sidebar sessions, Oracles, tracked PRs, beads and
/// Linear tickets) and on the chain view's strip. Clicking it opens the chain on the
/// member the badge sits on.
///
/// The color comes from `ChainPalette`, so one chain is one color everywhere. A closed
/// chain draws grey: it keeps its members, but is no longer what you are working on.
struct ChainBadge: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    /// The item this badge is drawn on, so the click lands on its tab. Nil opens the
    /// chain on its remembered tab.
    var member: ChainMemberRef? = nil
    /// Just a tinted link glyph, for rows with no room for the slug.
    var compact = false
    /// Run before the chain opens, for a surface that has to get out of the way
    /// (a popover that would otherwise sit on top of the chain view).
    var willOpen: (() -> Void)? = nil
    /// False where the badge only labels the chain already open (the strip).
    var opens = true
    /// Point size of the slug; the glyph follows it.
    var size: CGFloat = 9

    var body: some View {
        if opens {
            Button {
                willOpen?()
                model.openChain(slug: chain.slug, member: member)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .clickCursor()
        } else {
            label
        }
    }

    @ViewBuilder private var label: some View {
        if compact {
            Image(systemName: "link")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.18)))
                .help(help)
        } else {
            HStack(spacing: size / 3) {
                Image(systemName: "link").font(.system(size: size - 1, weight: .semibold))
                Text(chain.slug).font(.system(size: size, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, size * 0.55).padding(.vertical, size / 9)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(help)
        }
    }

    private var tint: Color {
        chain.isActive ? Self.color(for: chain.slug) : .secondary
    }

    private var help: String {
        let what = chain.isActive ? "Chain \(chain.slug)" : "Chain \(chain.slug) (closed)"
        return opens ? what + " — click to open it" : what
    }

    /// The slug's color, resolved per appearance so it follows a theme switch live.
    static func color(for slug: String) -> Color {
        func ns(_ dark: Bool) -> NSColor {
            let t = ChainPalette.tone(for: slug, dark: dark)
            return NSColor(calibratedHue: t.hue, saturation: t.saturation,
                           brightness: t.brightness, alpha: 1)
        }
        return Color(nsColor: .appAdaptive(light: ns(false), dark: ns(true)))
    }
}
