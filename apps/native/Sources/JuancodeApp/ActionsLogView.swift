import SwiftUI
import JuancodeServices

/// Failing CI logs the way the Actions web UI shows them: the errors up front, the
/// setup noise folded away, ANSI colour kept — so a red build can be diagnosed in
/// the GitHub panel instead of on the site. Parsing is `parseActionsLog`; this file
/// only maps the parse onto views and SGR codes onto colours (the same split as
/// `VimSyntaxPalette`).
struct ActionsLogView: View {
    /// Raw text from `getFailedCheckLogs`.
    let text: String

    @State private var log: ActionsLog?
    @State private var showTimestamps = false
    /// Group ids the user has toggled away from their default fold state.
    @State private var toggled: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let log, !log.isEmpty {
                header(log)
                errorSummary(log)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.sections) { section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                // Still parsing, or nothing that looks like an Actions log (e.g. the
                // "No failing-step logs available." placeholder) — show it verbatim.
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: text) {
            // 20k chars of log is cheap to parse but not free — keep it off main.
            let raw = text
            log = await Task.detached(priority: .utility) { parseActionsLog(raw) }.value
        }
    }

    private func header(_ log: ActionsLog) -> some View {
        HStack(spacing: 6) {
            let errors = log.errorLines.count
            Text(errors == 0 ? "Failing steps" : "\(errors) error\(errors == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(errors == 0 ? .secondary : Color.red)
            if log.truncated {
                Text("log truncated")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Only the tail of the log was kept, to bound memory")
            }
            Spacer(minLength: 4)
            Button(showTimestamps ? "Hide times" : "Times") {
                showTimestamps.toggle()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
            .clickCursor()
        }
    }

    /// Every error line, above the fold — the whole point of the panel is not having
    /// to hunt for these.
    @ViewBuilder
    private func errorSummary(_ log: ActionsLog) -> some View {
        let errors = log.errorLines
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(errors) { line in
                    Text(line.text)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sectionView(_ section: ActionsLogSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: section.hasError ? "xmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(section.hasError ? Color.red : .secondary)
                Text(sectionTitle(section))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 4)
            ForEach(section.groups) { group in
                groupView(group)
            }
        }
    }

    private func sectionTitle(_ section: ActionsLogSection) -> String {
        // gh prints "UNKNOWN STEP" when it can't match a log line to a step in the
        // job — that's gh's bookkeeping, not something worth showing.
        let parts = [section.job, section.step]
            .filter { !$0.isEmpty && $0 != "UNKNOWN STEP" }
        return parts.isEmpty ? "log" : parts.joined(separator: " / ")
    }

    @ViewBuilder
    private func groupView(_ group: ActionsLogGroup) -> some View {
        if group.foldable {
            let open = isOpen(group)
            Button {
                toggled.formSymmetricDifference([group.id])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Text(group.title.isEmpty ? "group" : group.title)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    if !open {
                        Text("\(group.lines.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if group.hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.red)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            if open {
                lines(group)
            }
        } else {
            lines(group)
        }
    }

    /// Folds start open when something failed inside them, closed otherwise — a
    /// user toggle flips whichever default applies.
    private func isOpen(_ group: ActionsLogGroup) -> Bool {
        toggled.contains(group.id) ? !group.hasError : group.hasError
    }

    private func lines(_ group: ActionsLogGroup) -> some View {
        ForEach(group.lines) { line in
            HStack(alignment: .top, spacing: 4) {
                if showTimestamps {
                    Text(line.timestamp.map(logTimeFormatter.string(from:)) ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .leading)
                }
                Text(attributed(line))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, group.foldable ? 20 : 10)
            .background(rowBackground(line.severity))
        }
    }

    /// The line's spans with their SGR colour applied, tinted whole when the line
    /// carried an Actions severity (an `##[error]` line reads red even if the tool
    /// that printed it used no colour).
    private func attributed(_ line: ActionsLogLine) -> AttributedString {
        if let severityColor = ActionsLogPalette.color(for: line.severity) {
            var out = AttributedString(line.text)
            out.foregroundColor = severityColor
            return out
        }
        var out = AttributedString()
        for span in line.spans {
            var piece = AttributedString(span.text)
            piece.foregroundColor = ActionsLogPalette.color(forSgr: span.fg)
            if span.bold { piece.font = .system(size: 10, weight: .bold, design: .monospaced) }
            out.append(piece)
        }
        return out
    }

    private func rowBackground(_ severity: ActionsLogSeverity) -> Color {
        switch severity {
        case .error: return Color.red.opacity(0.12)
        case .warning: return Color.orange.opacity(0.10)
        default: return .clear
        }
    }
}

/// Time-of-day only: the date is the same for every line of a run, and the panel
/// is narrow.
private let logTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// SGR codes and Actions severities → colours. Kept in the view layer so the
/// parser stays SwiftUI-free and testable.
enum ActionsLogPalette {
    /// The tint for a whole line, or nil when the line has nothing to say and its
    /// own ANSI spans should speak.
    static func color(for severity: ActionsLogSeverity) -> Color? {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .blue
        case .debug, .command: return .secondary
        case .plain: return nil
        }
    }

    /// Map an ANSI foreground code (30–37 normal, 90–97 bright) to a colour that
    /// reads on both light and dark backgrounds; nil for the default foreground.
    static func color(forSgr code: Int?) -> Color {
        switch code {
        case 30, 90: return .secondary          // black/grey — never true black
        case 31, 91: return .red
        case 32, 92: return .green
        case 33, 93: return .orange             // yellow is unreadable on light
        case 34, 94: return .blue
        case 35, 95: return .purple
        case 36, 96: return .teal
        case 37, 97: return .primary            // white — the default foreground
        default: return .primary
        }
    }
}
