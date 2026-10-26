import SwiftUI
import JuancodeCore

// The right rail's Chains panel: every active chain with how many items it holds and
// what in it is waiting on you, a click to open its chain view, a close action, and
// the closed ones behind an Inactive disclosure to reopen. The writes go through
// AppModel's chain passthroughs and the list follows the daemon's broadcast, so a
// close shows up here when the book says so, never optimistically.

struct ChainsRailPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chains.rail.showInactive") private var showInactive = false

    var body: some View {
        let active = model.chains.active
        let inactive = model.chains.inactive
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !model.supportsChains {
                    note("This core doesn't keep chains.")
                } else if active.isEmpty {
                    note(inactive.isEmpty
                         ? "No chains yet. Tag sessions, PRs and tickets into one to group related work."
                         : "No active chains.")
                }
                ForEach(active) { ChainRailRow(chain: $0) }
                if !inactive.isEmpty {
                    inactiveToggle(count: inactive.count)
                    if showInactive {
                        ForEach(inactive) { ChainRailRow(chain: $0) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .reportsRailOverflow()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func inactiveToggle(count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showInactive.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(showInactive ? 90 : 0))
                Text("Inactive")
                Text("\(count)").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase).tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showInactive ? "Hide closed chains" : "Show closed chains, to reopen one")
        .clickCursor()
    }
}

/// The Chains header's accessory: how many members across the active chains are
/// waiting on you, so a collapsed panel still says so.
struct ChainsRailAccessory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = model.chains.active.reduce(0) { $0 + model.chainAttention($1).total }
        if total > 0 {
            Text("\(total)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.22)))
                .foregroundStyle(.orange)
                .help("\(total) in your chains waiting on you")
        }
    }
}

/// One chain: its badge, member count and attention, open on click, close or reopen
/// on hover and from the context menu. Also a drop target for tagging items into it.
private struct ChainRailRow: View {
    @Environment(AppModel.self) private var model
    let chain: Chain
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let attention = model.chainAttention(chain)
        let open = model.chainView?.slug == chain.slug
        HStack(spacing: 6) {
            // The row is the click target; the badge only labels it.
            ChainBadge(chain: chain, opens: false, size: 10)
            Text(chain.members.count == 1 ? "1 item" : "\(chain.members.count) items")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if attention.waitingInput > 0 {
                pill(attention.waitingInput, icon: "hand.raised.fill",
                     help: attention.waitingInput == 1 ? "A session is waiting for input"
                         : "\(attention.waitingInput) sessions are waiting for input")
            }
            if attention.needsDecision > 0 {
                pill(attention.needsDecision, icon: "exclamationmark.bubble.fill",
                     help: attention.needsDecision == 1 ? "A PR needs your decision"
                         : "\(attention.needsDecision) PRs need your decision")
            }
            // Always laid out, only shown on hover: inserting it grew the row and
            // shifted every row under it.
            stateButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(open ? Color.appSelection : Color.appHairline(hovering ? 0.1 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .opacity(targeted ? 1 : 0))
        .opacity(chain.isActive ? 1 : 0.6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.openChain(slug: chain.slug) }
        .onHover { hovering = $0 }
        .clickCursor()
        .help(chain.isActive ? "Open chain \(chain.slug)" : "Open chain \(chain.slug) (closed)")
        .contextMenu {
            Button("Open Chain") { model.openChain(slug: chain.slug) }
            Button("Show Details…") { model.showChainDetail(slug: chain.slug) }
            if chain.isActive {
                Button("Close Chain") { close() }
            } else {
                Button("Reopen Chain") { reopen() }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            targeted = false
            return ChainDrop.accept(items, into: chain, model: model)
        } isTargeted: { targeted = $0 && chain.isActive }
    }

    private var stateButton: some View {
        Button {
            chain.isActive ? close() : reopen()
        } label: {
            Image(systemName: chain.isActive ? "xmark" : "arrow.uturn.backward")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(chain.isActive ? "Close chain — it keeps its members and can be reopened"
                             : "Reopen chain")
        .clickCursor()
    }

    private func pill(_ count: Int, icon: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text("\(count)").font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.22)))
        .foregroundStyle(.orange)
        .help(help)
    }

    private func close() {
        // Closing the chain on screen leaves its view, like any other way out of it.
        if model.chainView?.slug == chain.slug { model.exitChain() }
        Task { await model.closeChain(chain.slug) }
    }

    private func reopen() {
        Task { await model.reopenChain(chain.slug) }
    }
}

/// What dropping onto a chain row tags into it. The app's drags carry plain strings;
/// today a sidebar session row (its session id) is the one that names a taggable item.
/// Other kinds (PR rows, tickets) can learn to drop here by teaching this one place.
enum ChainDrop {
    @MainActor
    static func accept(_ items: [String], into chain: Chain, model: AppModel) -> Bool {
        guard chain.isActive else { return false }
        let ids = items.filter { id in
            model.sessions.contains { $0.id == id }
                && !chain.contains(ChainMemberRef(kind: .session, ref: id))
        }
        guard !ids.isEmpty else { return false }
        Task {
            for id in ids { await model.setChain(chain.slug, for: .session, ref: id) }
        }
        return true
    }
}

extension AppModel {
    /// What in `chain` is waiting on you: sessions at a prompt, tracked PRs with an
    /// open decision.
    func chainAttention(_ chain: Chain) -> ChainAttention {
        ChainAttention(chain,
                       waiting: { activity($0) == .waitingInput },
                       deciding: { tracked[$0].map { !$0.notifications.isEmpty } ?? false })
    }
}
