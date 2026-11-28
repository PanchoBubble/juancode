import SwiftUI
import JuancodeCore

/// The chain an item is in, as a pill: its name in the chain's own color, drawn on
/// every row that can be a member (sidebar sessions, Oracles, tracked PRs, beads and
/// Linear tickets) and on the chain view's strip. Clicking it opens the chain's
/// graph.
///
/// The color comes from `ChainPalette`, so one chain is one color everywhere. A closed
/// chain draws grey: it keeps its members, but is no longer what you are working on.
struct ChainBadge: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    /// The item this badge labels. Opening the badge always shows the graph.
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
                model.openChain(slug: chain.slug)
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
                .foregroundStyle(glyph)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(Capsule().fill(fill))
                .help(help)
        } else {
            HStack(spacing: size / 3) {
                Image(systemName: "link").font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(glyph)
                Text(chain.name).font(.system(size: size, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, size * 0.55).padding(.vertical, size / 9)
            .background(Capsule().fill(fill))
            .foregroundStyle(tint)
            .help(help)
        }
    }

    private var tint: Color {
        chain.isActive ? Self.color(for: chain.slug) : .secondary
    }

    private var accent: Color {
        chain.isActive ? Self.accentColor(for: chain.slug) : .secondary
    }

    /// Two-tone: the main hue fading into the accent, so chains sharing a main hue
    /// still look different at a glance.
    private var fill: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.22), accent.opacity(0.22)],
                       startPoint: .leading, endPoint: .trailing)
    }

    /// The link glyph in both hues, so the pair reads even where the badge is too
    /// small for its background gradient to show (the sidebar's compact icon).
    private var glyph: LinearGradient {
        LinearGradient(colors: [tint, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var help: String {
        let what = chain.isActive ? "Chain \(chain.name)" : "Chain \(chain.name) (closed)"
        return opens ? what + " — click to open it" : what
    }

    /// The slug's color, resolved per appearance so it follows a theme switch live.
    static func color(for slug: String) -> Color {
        adaptive { ChainPalette.tone(for: slug, dark: $0) }
    }

    static func accentColor(for slug: String) -> Color {
        adaptive { ChainPalette.accentTone(for: slug, dark: $0) }
    }

    private static func adaptive(_ tone: (Bool) -> ChainPalette.Tone) -> Color {
        func ns(_ dark: Bool) -> NSColor {
            let t = tone(dark)
            return NSColor(calibratedHue: t.hue, saturation: t.saturation,
                           brightness: t.brightness, alpha: 1)
        }
        return Color(nsColor: .appAdaptive(light: ns(false), dark: ns(true)))
    }
}
