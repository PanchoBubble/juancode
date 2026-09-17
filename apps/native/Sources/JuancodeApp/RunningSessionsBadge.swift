// The toolbar's running-sessions badge: how many agents are alive right now, and
// the list behind it, with a kill for each one.
//
// It stands where the core pill used to (juancode). The pill was a permanent
// answer to a question asked about once a week — which core produced this window —
// so the count took the slot and the core moved into this popover's footer, where
// it still turns red/yellow the moment the daemon goes down or stale. Settings →
// Core keeps the full story.

import SwiftUI
import JuancodeClient
import JuancodeCore

struct RunningSessionsBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    /// Live agents, and how many are mid-turn. Both come off the model's
    /// projection: a toolbar body that filtered sessions itself would re-render on
    /// every activity edge in every session (juancode-2n0).
    ///
    /// "Running" means a live agent pty, which is the set the pause button sleeps —
    /// not the number of rows in the sidebar. Sleeping and exited rows count zero,
    /// editor panes and adopted external sessions never count, and Oracle's own
    /// hidden sessions do (they are tagged in the list so the number reconciles
    /// with what you can see).
    private var running: Int { model.runningSessionCount }
    private var busy: Int { model.busySessionCount }

    /// The core's own health still owns the colour when something is wrong with it —
    /// a stale daemon mirroring a two-hour-old core has to stay visible now that the
    /// pill is gone.
    private var coreDown: Bool { model.coreConnectionDown != nil }
    private var coreStale: Bool { model.coreSelection.daemonIsStale }

    private var tint: Color {
        if coreDown { return .red }
        if coreStale { return .yellow }
        return busy > 0 ? .orange : .primary
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 3) {
                Image(systemName: coreDown || coreStale
                      ? "exclamationmark.triangle.fill"
                      : (busy > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"))
                Text("\(running)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .accessibilityLabel("\(running) running session(s), \(busy) working")
        }
        .foregroundStyle(tint)
        .help(helpText)
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.runningSessionMetas.isEmpty {
                    Text("Nothing running.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                } else {
                    ForEach(model.runningSessionMetas, id: \.id) { meta in
                        row(meta)
                    }
                }
                Divider().padding(.vertical, 4)
                coreFooter
            }
            .frame(width: 300)
            .padding(.bottom, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Running").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 12)
            Text(busy > 0 ? "\(busy) working" : "all resting")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    /// One live agent: click the row to go to it, click the stop button to kill its
    /// agent. Kill keeps the session, its scrollback and any worktree (see
    /// `AppModel.killSession`), so it is one click here exactly as it is in the
    /// session row's context menu — what it costs is the turn in flight.
    private func row(_ meta: SessionMeta) -> some View {
        let activity = model.activity(meta.id)
        return HStack(spacing: 8) {
            Button {
                // `revealSession`, not a bare selection: an Oracle row is never the
                // sidebar selection, so setting it would look like a dead click.
                model.revealSession(meta.id)
                showing = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: glyph(activity))
                        .font(.system(size: 11))
                        .foregroundStyle(colour(activity))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(meta.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            // Oracle's sessions are hidden from the sidebar but counted
                            // here, so say which ones they are rather than leaving a
                            // number that doesn't add up against the rows on screen.
                            if model.isOracleSession(meta.id) {
                                Text("Oracle")
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text("\((meta.cwd as NSString).lastPathComponent) · \(label(activity))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .clickCursor()
            Button {
                model.killSession(meta.id)
            } label: {
                Image(systemName: "stop.circle").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Kill this agent — the row, its scrollback and any worktree are kept, "
                  + "but a turn in flight is lost")
            .clickCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// Where the core pill went: the active core, plus whatever is wrong with it.
    private var coreFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoreBadgeLabel(selection: model.coreSelection,
                           connectionDown: model.coreConnectionDown)
            if let down = model.coreConnectionDown {
                Text("Connection down: \(down). Sessions keep running in the daemon; "
                    + "the app is retrying.")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = model.coreSelection.unreachableReason {
                Text("Asked for the \(model.coreSelection.requested.rawValue) core and fell "
                    + "back: \(reason)")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.coreSelection.daemonWarnings) { warning in
                DaemonWarningRow(warning: warning)
            }
            Text("Settings → Core has the database path, wire version and capabilities.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
    }

    private func glyph(_ activity: SessionActivity?) -> String {
        switch activity {
        case .busy: return "circle.fill"
        case .waitingInput: return "questionmark.circle.fill"
        case .idle, nil: return "circle"
        }
    }

    private func colour(_ activity: SessionActivity?) -> Color {
        switch activity {
        case .busy: return .orange
        case .waitingInput: return .yellow
        case .idle, nil: return .secondary
        }
    }

    private func label(_ activity: SessionActivity?) -> String {
        switch activity {
        case .busy: return "working"
        case .waitingInput: return "waiting on you"
        case .idle, nil: return "idle"
        }
    }

    private var helpText: String {
        var parts = ["\(running) running session(s), \(busy) working"]
        if let down = model.coreConnectionDown { parts.append("core connection down: \(down)") }
        else if coreStale { parts.append("the daemon is stale") }
        return parts.joined(separator: " · ")
    }
}
