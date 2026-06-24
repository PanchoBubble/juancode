import SwiftUI
import JuancodeCore

/// Self-contained, composable visualization of a folder's bd (beads) issues
/// (juancode-9s0) — richer than the sidebar `FolderIssues` popover. Designed to
/// drop into the upcoming right-side tab switcher (juancode-fmh) as the "Issues"
/// tab: it takes a `cwd` and reads the in-process `AppModel` issue cache.
///
/// Issues are grouped into actionability sections (Ready / Blocked / In progress
/// / Open, plus an optional Closed section) via the pure `BeadsGrouping` logic,
/// each row showing status/priority/type badges and dependency context. Every
/// open issue offers a "Work on" action that calls `AppModel.workOnIssue` to
/// inject the issue's context into the folder's focused session (spawning one if
/// none exists). Read-only visualization plus that send action — no create/edit.
struct IssuesPanel: View {
    @EnvironmentObject var model: AppModel
    let cwd: String

    /// Optionally surface closed issues too (the panel can afford to, unlike the
    /// compact popover). Off by default — open work is what's actionable.
    @State private var showClosed = false
    @State private var query = ""

    private var result: BeadsResult? { model.beads(cwd) }

    private var filtered: [BeadsIssue] {
        guard let r = result, r.available else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return r.issues }
        return r.issues.filter { "\($0.id) \($0.title)".lowercased().contains(q) }
    }

    private var groups: [BeadsGroup] {
        BeadsGrouping.grouped(filtered, includeClosed: showClosed)
    }

    private var openCount: Int {
        (result?.available ?? false) ? (result?.issues.filter { !$0.isClosed }.count ?? 0) : 0
    }
    private var closedCount: Int {
        (result?.available ?? false) ? (result?.issues.filter { $0.isClosed }.count ?? 0) : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { if result == nil { model.loadBeads(cwd) } }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Issues").font(.system(size: 13, weight: .medium))
                if result?.available ?? false {
                    Text("\(openCount) open").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if closedCount > 0 {
                    Toggle("Closed (\(closedCount))", isOn: $showClosed)
                        .toggleStyle(.button).controlSize(.small).font(.system(size: 10))
                }
                Button { model.loadBeads(cwd) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh issues")
            }
            if result?.available ?? false {
                TextField("Filter issues…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if result == nil {
            centered("Loading issues…")
        } else if let r = result, !r.available {
            centered(r.error ?? "No beads tracker in this folder")
        } else if groups.isEmpty {
            centered(query.isEmpty ? "No open issues" : "No matching issues")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.section) { group in
                        IssueSectionHeader(title: group.section.title, count: group.issues.count)
                        ForEach(group.issues, id: \.id) { issue in
                            IssuePanelRow(issue: issue, cwd: cwd)
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small uppercased section divider (Ready / Blocked / …) with a count.
private struct IssueSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12).padding(.bottom, 4)
    }
}

/// One issue row in the panel: status dot, priority + type + dependency badges,
/// id + title, and (for open issues) a "Work on" send-to-agent action.
private struct IssuePanelRow: View {
    @EnvironmentObject var model: AppModel
    let issue: BeadsIssue
    let cwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(statusLabel)
                Badge(text: "p\(issue.priority)", palette: priorityPalette)
                Badge(text: issue.issueType, palette: .neutral)
                Text(issue.id).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if issue.dependencyCount > 0 {
                    DepBadge(systemName: "arrow.down.right", count: issue.dependencyCount,
                             help: "Depends on \(issue.dependencyCount) issue\(issue.dependencyCount == 1 ? "" : "s")")
                }
                if issue.dependentCount > 0 {
                    DepBadge(systemName: "arrow.up.right", count: issue.dependentCount,
                             help: "Blocks \(issue.dependentCount) issue\(issue.dependentCount == 1 ? "" : "s")")
                }
            }
            Text(issue.title).font(.system(size: 12)).lineLimit(2).help(issue.title)
            HStack(spacing: 8) {
                if let parent = issue.parent {
                    Text("↳ \(parent)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if !issue.isClosed {
                    Button("Work on") { model.workOnIssue(issue, cwd: cwd) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Inject this issue's context into the focused session (starts one if none)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if issue.isClosed { return .secondary }
        if issue.blocked { return .orange }
        if issue.ready { return .green }
        return .blue
    }
    private var statusLabel: String {
        if issue.isClosed { return "Closed" }
        if issue.blocked { return "Blocked" }
        if issue.ready { return "Ready" }
        return issue.status
    }
    private var priorityPalette: BadgePalette {
        switch issue.priority {
        case 0: return .red
        case 1: return .orange
        default: return .neutral
        }
    }
}

private enum BadgePalette { case red, orange, neutral }

/// A small pill badge (priority / type) with a palette.
private struct Badge: View {
    let text: String
    let palette: BadgePalette
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private var bg: Color {
        switch palette {
        case .red: return .red.opacity(0.18)
        case .orange: return .orange.opacity(0.18)
        case .neutral: return .secondary.opacity(0.15)
        }
    }
    private var fg: Color {
        switch palette {
        case .red: return .red
        case .orange: return .orange
        case .neutral: return .secondary
        }
    }
}

/// A dependency-count chip (depends-on / blocks).
private struct DepBadge: View {
    let systemName: String
    let count: Int
    let help: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemName).font(.system(size: 8))
            Text("\(count)").font(.system(size: 9))
        }
        .foregroundStyle(.secondary)
        .help(help)
    }
}
