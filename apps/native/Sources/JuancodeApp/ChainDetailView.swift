import SwiftUI
import AppKit
import JuancodeCore
import JuancodeDesktop

// The chain detail sheet: one chain's members grouped by kind (sessions, Oracles,
// PRs, tickets) with status, project and last activity, a search across all of them,
// per-row "open as tab" and "remove from chain", and the chain's close/reopen/delete.
// Shown by `AppModel.showChainDetail(slug:)`; the grouping and the filter are pure,
// in JuancodeCore/ChainDetail.swift.

struct ChainDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let slug: String
    @State private var query = ""
    @State private var confirmDelete = false
    @State private var confirmRemove: ChainDetailRow?
    @AppStorage(ChainOverviewMode.storageKey) private var graphMode = ChainOverviewMode.graph.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if let chain = model.chains[slug] {
                header(chain)
                Divider()
                list(chain)
            } else {
                // Deleted under the sheet; `applyChains` dismisses it on the same update.
                Spacer()
            }
        }
        .frame(width: 640, height: 520)
        .alert("Delete chain \u{201C}\(slug)\u{201D}?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { if await model.deleteChain(slug) { dismiss() } }
            }
        } message: {
            Text("The chain goes away; its sessions, PRs and tickets are untouched.")
        }
        .alert("Remove from chain?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmRemove = nil }
            Button("Remove", role: .destructive) {
                if let row = confirmRemove { remove(row) }
                confirmRemove = nil
            }
        } message: {
            Text("\u{201C}\(confirmRemove?.title ?? "")\u{201D} leaves \u{201C}\(slug)\u{201D}. "
                + "The item itself is untouched.")
        }
    }

    private func header(_ chain: Chain) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChainBadge(chain: chain, opens: false, size: 11)
                Text(summary(chain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    graphMode = ChainOverviewMode.graph.rawValue
                    model.chainDetail = nil
                    model.openChain(slug: slug)
                } label: {
                    Label("Open Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .keyboardShortcut(.defaultAction)
                .help("Open this chain as a graph of connected sessions, handoffs, tickets and PRs")
                .clickCursor()
                Menu {
                    if chain.isActive {
                        Button("Close Chain") { Task { await model.closeChain(slug) } }
                    } else {
                        Button("Reopen Chain") { Task { await model.reopenChain(slug) } }
                    }
                    Divider()
                    Button("Delete Chain\u{2026}", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Close, reopen or delete this chain")
                .clickCursor()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .clickCursor()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions, Oracles, PRs and tickets", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .clickCursor()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.appHairline(0.08)))
        }
        .padding()
    }

    private func summary(_ chain: Chain) -> String {
        let n = chain.members.count
        let members = "\(n) member\(n == 1 ? "" : "s")"
        if chain.isActive { return "\(members) · started \(relativeTime(chain.createdAt))" }
        return "\(members) · closed \(chain.closedAt.map(relativeTime) ?? "")"
    }

    @ViewBuilder private func list(_ chain: Chain) -> some View {
        let sections = ChainDetail.sections(model.chainDetailRows(chain), query: query)
        if sections.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: chain.members.isEmpty ? "link" : "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(chain.members.isEmpty ? "Nothing in this chain yet" : "No member matches \u{201C}\(query)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                ChainDetailRowView(row: row,
                                                   open: { open(row) },
                                                   remove: { confirmRemove = row })
                            }
                        } header: {
                            HStack {
                                Text(section.group.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(section.rows.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                            .background(Color.appSurface)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .background(Color.appSurface)
        }
    }

    private func open(_ row: ChainDetailRow) {
        model.openChainMemberFromDetail(slug: slug, member: row.id)
    }

    private func remove(_ row: ChainDetailRow) {
        Task { await model.setChain(nil, for: row.member.kind, ref: row.member.ref) }
    }
}

/// One member: its kind's icon, title, project, status and last activity, with the
/// row actions on hover and in the context menu. Double-click opens it as a tab.
private struct ChainDetailRowView: View {
    @Environment(AppModel.self) private var model
    let row: ChainDetailRow
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = ChainTabLabel(row.member, model: model)
        HStack(spacing: 10) {
            Image(systemName: label.icon)
                .font(.system(size: 12))
                .foregroundStyle(label.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(row.member.kind == .session ? row.project ?? "" : row.member.ref)
                        .lineLimit(1)
                    if row.member.kind != .session, let project = row.project {
                        Text("·")
                        Text(project).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let status = row.status {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.appHairline(0.1)))
                    .foregroundStyle(label.missing ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            Text(relativeTime(row.activityAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
                .help(row.lastActivity == nil ? "Joined the chain" : "Last activity")
            HStack(spacing: 2) {
                Button(action: open) { Image(systemName: "rectangle.stack") }
                    .help("Open as a tab in the chain view")
                    .disabled(label.missing)
                Button(action: remove) { Image(systemName: "link.badge.minus") }
                    .help("Remove from this chain")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .clickCursor()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.appHairline(hovering ? 0.08 : 0))
        .opacity(label.missing ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !label.missing { open() } }
        .contextMenu {
            Button("Open as Tab", action: open).disabled(label.missing)
            if let url = URL(string: row.member.url ?? model.tracked[row.member.ref]?.url ?? ""),
               url.scheme != nil {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Remove from Chain", action: remove)
        }
        .help(label.help)
    }
}

extension AppModel {
    /// A beads issue in whichever loaded tracker has it, with that tracker's cwd. A
    /// beads ref carries no project, so this looks across every listing loaded.
    func beadsIssue(id: String) -> (issue: BeadsIssue, cwd: String)? {
        for (cwd, result) in beadsByCwd {
            if let issue = result.issues.first(where: { $0.id == id }) { return (issue, cwd) }
        }
        return nil
    }

    /// `chain`'s members described for the detail view from this app's own stores.
    func chainDetailRows(_ chain: Chain) -> [ChainDetailRow] {
        chain.members.map { member in
            let group = ChainDetailGroup.of(member, isOracle: isOracleSession)
            switch member.kind {
            case .session:
                guard let meta = sessions.first(where: { $0.id == member.ref }) else {
                    return ChainDetailRow(member: member, group: group, title: member.title ?? member.ref,
                                          status: "Gone")
                }
                return ChainDetailRow(
                    member: member, group: group, title: meta.title,
                    project: group == .oracles ? "Oracle" : (repoRoot(forSession: meta) as NSString).lastPathComponent,
                    status: sessionStatus(meta), lastActivity: meta.updatedAt,
                    keywords: [meta.provider.rawValue, meta.cwd])
            case .trackedPr:
                let ref = ChainPrRef(member.ref)
                let pr = tracked[member.ref]
                return ChainDetailRow(
                    member: member, group: group,
                    title: pr?.title ?? member.title ?? ref.number.map { "PR #\($0)" } ?? member.ref,
                    project: ref.project, status: pr.map { trackStateLabel($0.state) } ?? "Not tracked",
                    lastActivity: pr?.lastPolledAt, keywords: [pr?.branch ?? ""])
            case .beads:
                let found = beadsIssue(id: member.ref)
                return ChainDetailRow(
                    member: member, group: group, title: found?.issue.title ?? member.title ?? member.ref,
                    project: found.map { ($0.cwd as NSString).lastPathComponent },
                    status: found?.issue.status.replacingOccurrences(of: "_", with: " "),
                    keywords: ["beads", found?.issue.issueType ?? ""])
            case .linear:
                let issue = trackedIssues.values.first { $0.identifier == member.ref }
                return ChainDetailRow(
                    member: member, group: group, title: issue?.title ?? member.title ?? member.ref,
                    project: issue.map { ($0.cwd as NSString).lastPathComponent },
                    status: issue.flatMap { $0.lastStateName.isEmpty ? nil : $0.lastStateName },
                    lastActivity: issue?.lastPolledAt, keywords: ["linear"])
            }
        }
    }

    private func sessionStatus(_ meta: SessionMeta) -> String {
        guard isLive(meta.id) else { return meta.dormant ? "Sleeping" : "Exited" }
        switch activities[meta.id] {
        case .busy: return "Working"
        case .waitingInput: return "Needs input"
        case .idle, nil: return "Idle"
        }
    }

    private func trackStateLabel(_ state: TrackState) -> String {
        switch state {
        case .watching: return "Watching"
        case .fixing: return "Fixing"
        case .needsDecision: return "Needs decision"
        }
    }
}
