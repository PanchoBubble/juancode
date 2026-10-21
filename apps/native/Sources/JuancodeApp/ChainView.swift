import SwiftUI
import AppKit
import JuancodeCore
import JuancodeDesktop

// The chain view: opening a chain puts a strip over the detail area
// — the chain's badge, an exit button, and one tab per member. A session tab is the
// selection itself, so its pane is the ordinary keep-alive session pane underneath;
// every other tab draws one of the cards below over it. The open/exit/tab API is on
// AppModel (`openChain(slug:member:)` and friends), so entry points never reach in here.

/// The strip across the top of the detail area while a chain is open.
struct ChainTabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(Shortcuts.self) private var shortcuts
    let chain: Chain
    let selected: ChainMemberRef?

    var body: some View {
        HStack(spacing: 8) {
            ChainBadge(chain: chain, opens: false, size: 11)
            Button {
                model.exitChain()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Leave the chain and go back to where you were (\(shortcuts.binding(for: .toggleChain).display))")
            .clickCursor()
            Divider().frame(height: 16)
            if chain.members.isEmpty {
                Text("Nothing in this chain yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(chain.members, id: \.memberRef) { member in
                                ChainTab(member: member, active: member.memberRef == selected)
                                    .id(member.memberRef)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onChange(of: selected) { _, tab in
                        if let tab { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tab) } }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.appBand)
    }
}

/// One member's tab: an icon for its kind, and what tells it apart from the rest of
/// a cross-project chain — project and provider, a PR's number, a ticket's id.
private struct ChainTab: View {
    @Environment(AppModel.self) private var model
    let member: ChainMember
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let label = ChainTabLabel(member, model: model)
        Button {
            model.selectChainMember(member.memberRef)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: label.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(label.tint)
                Text(label.title)
                    .font(.caption.weight(active ? .semibold : .regular))
                    .lineLimit(1)
                if let detail = label.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(active ? Color.appSelection : Color.appHairline(hovering ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(label.missing ? 0.55 : 1)
        .onHover { hovering = $0 }
        .help(label.help)
        .clickCursor()
    }
}

/// What a member's tab says about it.
struct ChainTabLabel {
    var icon: String
    var title: String
    var detail: String?
    var tint: Color = .secondary
    var help: String
    /// The item it names is gone (a deleted session); the tab stays until the
    /// daemon untags it.
    var missing = false

    @MainActor
    init(_ member: ChainMember, model: AppModel) {
        switch member.kind {
        case .session:
            let meta = model.sessions.first { $0.id == member.ref }
            let live = model.isLive(member.ref)
            tint = live ? .green : .secondary
            if model.isOracleSession(member.ref) {
                icon = "sparkle"
                title = "Oracle"
                detail = meta?.provider.rawValue
                help = "Oracle — " + (meta?.title ?? member.ref)
            } else if let meta {
                icon = "terminal"
                title = (model.repoRoot(forSession: meta) as NSString).lastPathComponent
                detail = meta.provider.rawValue
                help = meta.title
            } else {
                icon = "terminal"
                title = member.title ?? "Session"
                detail = "gone"
                help = "This session no longer exists"
                missing = true
            }
        case .trackedPr:
            let pr = ChainPrRef(member.ref)
            icon = "arrow.triangle.pull"
            title = pr.number.map { "#\($0)" } ?? member.ref
            detail = pr.project
            tint = model.tracked[member.ref]?.snapshot.checks.color ?? .secondary
            help = model.tracked[member.ref]?.title ?? member.title ?? member.ref
        case .beads, .linear:
            icon = member.kind == .beads ? "circle.hexagongrid" : "ticket"
            title = member.ref
            detail = nil
            help = member.title ?? member.ref
        }
    }
}

/// A tracked PR's member ref, `<cwd>#<number>`, taken apart.
struct ChainPrRef {
    let cwd: String
    let number: Int?

    init(_ ref: String) {
        if let hash = ref.lastIndex(of: "#") {
            cwd = String(ref[..<hash])
            number = Int(ref[ref.index(after: hash)...])
        } else {
            cwd = ref
            number = nil
        }
    }

    var project: String { (cwd as NSString).lastPathComponent }
}

/// What the detail area shows for a tab that is not a session pane. Opaque, over the
/// still-mounted session container, so going back to a session tab is instant.
struct ChainMemberCard: View {
    @Environment(AppModel.self) private var model
    let member: ChainMember

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch member.kind {
                case .session:
                    if model.isOracleSession(member.ref) {
                        ChainOracleCard(member: member)
                    } else {
                        ChainGoneCard(member: member)
                    }
                case .trackedPr: ChainPrCard(member: member)
                case .beads, .linear: ChainTicketCard(member: member)
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.appPanel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.appDivider))
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appSurface)
        // The session pane under the card still holds the keyboard; typing at a card
        // must not land in a terminal you cannot see.
        .onAppear { model.hostWindow?.makeFirstResponder(nil) }
    }
}

/// One labelled line of a card.
private struct CardRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct CardHeader: View {
    let icon: String
    let kicker: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(kicker, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
        }
    }
}

/// A button to a session from a card: its tab when it is in the chain, else the
/// session itself (which leaves the chain, like any other navigation).
private struct LinkedSessionButton: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        if let meta = model.sessions.first(where: { $0.id == sessionId }) {
            Button {
                let tab = ChainMemberRef(kind: .session, ref: sessionId)
                if let slug = model.chainView?.slug, model.chains[slug]?.contains(tab) == true {
                    model.selectChainMember(tab)
                } else {
                    model.selection = sessionId
                }
            } label: {
                Label(meta.title, systemImage: model.isLive(sessionId) ? "terminal.fill" : "terminal")
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .clickCursor()
        } else {
            Text("gone").foregroundStyle(.secondary)
        }
    }
}

private struct ChainPrCard: View {
    @Environment(AppModel.self) private var model
    let member: ChainMember

    var body: some View {
        let ref = ChainPrRef(member.ref)
        let tracked = model.tracked[member.ref]
        let number = ref.number.map { "#\($0)" } ?? ""
        CardHeader(icon: "arrow.triangle.pull", kicker: "Pull request \(number) · \(ref.project)",
                   title: tracked?.title ?? member.title ?? "PR \(number)")
        if let tracked {
            CardRow(label: "State") { TrackBadge(state: tracked.state) }
            CardRow(label: "Checks") {
                Label(checksLabel(tracked.snapshot.checks), systemImage: tracked.snapshot.checks.icon)
                    .foregroundStyle(tracked.snapshot.checks.color)
            }
            CardRow(label: "Branch") { Text(tracked.branch).font(.callout.monospaced()) }
            CardRow(label: "Session") { LinkedSessionButton(sessionId: tracked.sessionId) }
            if !tracked.notifications.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs your decision").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(tracked.notifications) { note in
                        Text(note.message).font(.callout).textSelection(.enabled)
                    }
                }
            }
        } else {
            CardRow(label: "State") { Text("Not tracked").foregroundStyle(.secondary) }
        }
        CardRow(label: "Project") { Text((ref.cwd as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()) }
        if let url = URL(string: tracked?.url ?? member.url ?? "") {
            CardRow(label: "Link") { Link(url.absoluteString, destination: url).lineLimit(1).truncationMode(.middle) }
        }
    }

    private func checksLabel(_ checks: PrChecks) -> String {
        switch checks {
        case .passing: return "Passing"
        case .failing: return "Failing"
        case .pending: return "Running"
        case .none: return "No checks"
        }
    }
}

private struct ChainTicketCard: View {
    @Environment(AppModel.self) private var model
    let member: ChainMember

    var body: some View {
        if member.kind == .beads {
            let found = beadsIssue
            CardHeader(icon: "circle.hexagongrid", kicker: "Beads · \(member.ref)",
                       title: found?.issue.title ?? member.title ?? member.ref)
            if let found {
                CardRow(label: "Status") { Text(found.issue.status.replacingOccurrences(of: "_", with: " ")) }
                CardRow(label: "Priority") { Text("P\(found.issue.priority) · \(found.issue.issueType)") }
                CardRow(label: "Project") { Text((found.cwd as NSString).lastPathComponent) }
                Button("Open in Beads") {
                    model.beadsBoard.openProject(found.cwd)
                    model.beadsBoard.ticket = member.ref
                    model.showingBeads = true
                }
                .clickCursor()
            } else {
                CardRow(label: "Status") { Text("Not in any loaded tracker").foregroundStyle(.secondary) }
            }
        } else {
            let tracked = model.trackedIssues.values.first { $0.identifier == member.ref }
            CardHeader(icon: "ticket", kicker: "Linear · \(member.ref)",
                       title: tracked?.title ?? member.title ?? member.ref)
            if let tracked {
                if !tracked.lastStateName.isEmpty {
                    CardRow(label: "Status") { Text(tracked.lastStateName) }
                }
                CardRow(label: "Session") { LinkedSessionButton(sessionId: tracked.sessionId) }
            }
        }
        if let url = URL(string: member.url ?? ""), !(member.url ?? "").isEmpty {
            CardRow(label: "Link") { Link(url.absoluteString, destination: url).lineLimit(1).truncationMode(.middle) }
        }
    }

    /// The issue in whichever loaded tracker has it. The ref carries no project, so
    /// this is a lookup across every listing the app has loaded.
    private var beadsIssue: (issue: BeadsIssue, cwd: String)? {
        for (cwd, result) in model.beadsByCwd {
            if let issue = result.issues.first(where: { $0.id == member.ref }) { return (issue, cwd) }
        }
        return nil
    }
}

/// An Oracle tab. Its live terminal is the Oracle dock's — the one surface an Oracle
/// is drawn on — which the tab already slid in; this card is what is left behind
/// when the dock is closed.
private struct ChainOracleCard: View {
    @Environment(AppModel.self) private var model
    let member: ChainMember

    var body: some View {
        let meta = model.sessions.first { $0.id == member.ref }
        CardHeader(icon: "sparkle", kicker: "Oracle · \(meta?.provider.rawValue ?? "")",
                   title: meta?.title ?? member.title ?? "Oracle")
        Text("This Oracle runs in the Oracle dock.")
            .font(.callout)
            .foregroundStyle(.secondary)
        Button("Show Oracle") { model.revealOracle?(member.ref) }
            .clickCursor()
    }
}

private struct ChainGoneCard: View {
    let member: ChainMember

    var body: some View {
        CardHeader(icon: "terminal", kicker: "Session", title: member.title ?? member.ref)
        Text("This session no longer exists.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
