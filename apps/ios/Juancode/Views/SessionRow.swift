import JuancodeWire
import SwiftUI

/// Design tokens from the iOS dock redesign (juancode-3aq8.10).
enum Tok {
    static let bg = Color(hex: 0x000000)
    static let bg2 = Color(hex: 0x0B0B0D)
    static let surface = Color(hex: 0x1C1C1E)
    static let surface2 = Color(hex: 0x2C2C2E)
    static let text = Color(hex: 0xF2F2F7)
    static let secondary = Color(hex: 0x8E8E93)
    static let blue = Color(hex: 0x0A84FF)
    static let waiting = Color(hex: 0xFF9F0A)
    static let waitingBg = Color(hex: 0x2A1F0E)
    static let chain = Color(hex: 0xBF5AF2)
    static let chainBg = Color(hex: 0x2A1F33)
    static let claude = Color(hex: 0xD97757)
    static let claudeBg = Color(hex: 0x3A2620)

    static func context(_ pct: Int) -> Color {
        pct >= 85 ? Color(hex: 0xFF453A) : pct >= 60 ? Color(hex: 0xFFD60A) : Color(hex: 0x30D158)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension SessionMeta {
    var displayTitle: String { title.isEmpty ? provider.rawValue : title }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

extension RemoteCore {
    /// nil = exited or not yet reported.
    func liveActivity(_ s: SessionMeta) -> SessionActivity? { s.status == .exited ? nil : activity[s.id] }
    func isWaiting(_ s: SessionMeta) -> Bool { liveActivity(s) == .waitingInput }
}

/// The one session row used everywhere: project sessions, Active, Search, chain members.
struct SessionRow: View {
    let core: RemoteCore
    let session: SessionMeta

    var body: some View {
        let waiting = core.isWaiting(session)
        let exited = session.status == .exited
        HStack(spacing: 12) {
            ProviderBadge(provider: session.provider)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.displayTitle).font(.body.weight(.medium)).foregroundStyle(Tok.text).lineLimit(1)
                    Spacer(minLength: 4)
                    StatusLabel(state: core.liveActivity(session), exited: exited)
                }
                HStack(spacing: 6) {
                    Text(session.projectName).font(.subheadline).foregroundStyle(Tok.secondary).lineLimit(1)
                    if let chain = core.chains.chain(forSession: session.id) {
                        ChainChip(name: chain.name,
                                  role: chain.members.first { $0.kind == .session && $0.ref == session.id }?.role)
                    }
                }
            }
            ContextMeter(percent: session.usage?.contextPercent)
        }
        .padding(12)
        .background(waiting ? Tok.waitingBg : Tok.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { if waiting { RoundedRectangle(cornerRadius: 12).stroke(Tok.waiting, lineWidth: 1) } }
        .opacity(exited ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ProviderBadge: View {
    let provider: ProviderId
    var size: CGFloat = 32

    var body: some View {
        let claude = provider == .claude
        Image(systemName: claude ? "asterisk" : "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(claude ? Tok.claude : Tok.text)
            .frame(width: size, height: size)
            .background(claude ? Tok.claudeBg : Tok.surface2, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityLabel(provider.rawValue)
    }
}

struct StatusLabel: View {
    let state: SessionActivity?
    let exited: Bool

    var body: some View {
        if state == .waitingInput {
            Label("Needs input", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Tok.waiting, in: RoundedRectangle(cornerRadius: 5))
        } else {
            HStack(spacing: 4) {
                StatusDot(state: state, size: 7)
                Text(exited ? "Exited" : state == .busy ? "Working" : state == .idle ? "Idle" : "—")
                    .font(.caption).foregroundStyle(state == .busy ? Tok.blue : Tok.secondary)
            }
        }
    }
}

struct StatusDot: View {
    /// nil = exited or not yet reported.
    let state: SessionActivity?
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .accessibilityLabel(state.map { "\($0.rawValue)" } ?? "unknown")
    }

    private var color: Color {
        switch state {
        case .busy: Tok.blue
        case .waitingInput: Tok.waiting
        case .idle: .green
        case nil: .gray
        }
    }
}

struct ChainChip: View {
    let name: String
    let role: String?

    var body: some View {
        Label(role.map { "\(name) · \($0)" } ?? name, systemImage: "link")
            .font(.caption).foregroundStyle(Tok.chain).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Tok.chainBg, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Context-window fill; "—" with an empty track when the CLI has not reported it.
struct ContextMeter: View {
    let percent: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(percent.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit())
                .foregroundStyle(percent.map { $0 >= 85 ? Tok.context($0) : Tok.text } ?? Tok.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.surface2)
                if let percent {
                    Capsule().fill(Tok.context(percent)).frame(width: 38 * CGFloat(min(percent, 100)) / 100)
                }
            }
            .frame(width: 38, height: 4)
        }
        .accessibilityLabel(percent.map { "Context \($0) percent" } ?? "Context unknown")
    }
}
