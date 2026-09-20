// The toolbar's running-sessions badge: how many agents are alive right now, the
// list behind it with a kill for each one, and the global pause on top of that list.
//
// The pause used to be its own toolbar button next to this one, reading the same
// count off the same projection and drawing it in a second glyph. It is one control
// now: the number here is what a pause would sleep, and once the pause holds it is
// what a resume would bring back.
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
    /// The pause confirmation. It lives here rather than on the popover row so the
    /// dialog survives the popover closing underneath it.
    @State private var confirmingPause = false
    /// Whether the app itself is behind the checkout it was built from (juancode-b06m).
    /// Kept here rather than on `AppModel` because nothing else needs it and the
    /// answer costs four `git` execs: this view is the only thing that asks.
    @State private var buildWarning: AppBuildWarning?

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

    /// The global pause, folded in from the toolbar button that used to sit next to
    /// this one showing the same number in a second glyph. While it holds there is
    /// nothing running, so the badge speaks for the sleeping set instead: the count
    /// becomes what a resume would bring back, not a zero.
    private var paused: Bool { model.isGloballyPaused }
    private var pausedCount: Int { model.pausedSessionCount }

    /// What the badge counts: the live agents, or — under a global pause — the ones
    /// asleep waiting for the resume.
    private var badgeCount: Int { paused ? pausedCount : running }

    /// The core's own health still owns the colour when something is wrong with it —
    /// a stale daemon mirroring a two-hour-old core has to stay visible now that the
    /// pill is gone.
    private var coreDown: Bool { model.coreConnectionDown != nil }
    private var coreStale: Bool { model.coreSelection.daemonIsStale }

    /// The app's own build, held to the same standard as the daemon's. The daemon has
    /// said "I am older than your checkout" since it became a separate process; the
    /// app could not, so a landed toolbar fix read as a bug for a day.
    private var appStale: Bool { buildWarning != nil }

    private var tint: Color {
        if coreDown { return .red }
        if coreStale || appStale { return .yellow }
        return paused || busy > 0 ? .orange : .primary
    }

    /// Core health outranks the pause: a daemon that has gone stale or unreachable
    /// has to stay visible even while everything is asleep, so it keeps the glyph.
    private var glyph: String {
        if coreDown || coreStale || appStale { return "exclamationmark.triangle.fill" }
        if paused { return "pause.circle.fill" }
        return busy > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    private var badgeLabel: String {
        paused
            ? "\(pausedCount) paused session(s), all agents asleep"
            : "\(running) running session(s), \(busy) working"
    }

    var body: some View {
        Button {
            showing = true
            // Opening the badge is the one user-initiated moment worth re-measuring
            // at: the checkout moves while the app is open (that is the whole
            // scenario), and the actor's own floor keeps this to once every 5 min.
            Task { buildWarning = await AppBuildDrift.shared.warning() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: glyph)
                Text("\(badgeCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .accessibilityLabel(badgeLabel)
        }
        .foregroundStyle(tint)
        .help(helpText)
        .clickCursor()
        .task { buildWarning = await AppBuildDrift.shared.warning() }
        .confirmationDialog("Pause \(running) running session(s)?",
                            isPresented: $confirmingPause, titleVisibility: .visible) {
            Button("Pause All") { model.pauseAllSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each agent is stopped and its memory freed. Resume reloads the "
                 + "conversation with --resume, so a turn that is mid-flight now is lost.")
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                pauseRow
                Divider().padding(.vertical, 2)
                header
                if model.runningSessionMetas.isEmpty {
                    Text(paused ? "All asleep — resume brings them back." : "Nothing running.")
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

    /// The global pause, first thing in the popover.
    ///
    /// Pause is the per-session sleep applied to all of them, so it genuinely returns
    /// the RAM — the reason to reach for it is memory pressure or walking away. It
    /// asks first, because resume runs `--resume`, a reload rather than a
    /// continuation of the turn in flight. Resume itself is one click.
    ///
    /// With nothing to pause the row goes disabled rather than disappearing, so the
    /// popover keeps its shape whatever the app is doing.
    private var pauseRow: some View {
        Button {
            showing = false
            if paused {
                model.resumeAllSessions()
            } else {
                // One runloop turn after the popover closes: a confirmation raised in
                // the same update as the dismissal can be swallowed by it.
                DispatchQueue.main.async { confirmingPause = true }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: paused ? "play.circle.fill" : "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(paused ? Color.orange : .secondary)
                    .frame(width: 18)
                Text(paused ? "Resume (\(pausedCount))" : "Pause all (\(running))")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if !paused, busy > 0 {
                    Text("\(busy) working")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 7)
            .accessibilityLabel(paused
                                ? "Resume All, \(pausedCount) paused"
                                : "Pause All, \(running) running")
        }
        .buttonStyle(.plain)
        .disabled(!paused && running == 0)
        .clickCursor()
        .help(paused
              ? "Resume the \(pausedCount) session(s) the pause put to sleep"
              : "Pause all — sleep \(running) running session(s) "
                + "(\(busy) working right now) and free their memory")
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
            // Beside the session list itself: whether these rows are still here after
            // Cmd-Q is a fact about the list, not a footnote about the core.
            if let persistence = model.coreSelection.sessionPersistence {
                DaemonPersistenceRow(note: persistence)
            }
            ForEach(model.coreSelection.daemonWarnings) { warning in
                BuildWarningRow(warning)
            }
            // The app's own staleness sits with the core's because they are the same
            // question asked of two processes, and because a reader who has learned
            // that yellow-triangle-here means "the build on screen is not the build
            // you compiled" should not have to learn a second place for the half of
            // it that is the app.
            if let buildWarning {
                BuildWarningRow(buildWarning)
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
        var parts = [paused
                     ? "paused — \(pausedCount) session(s) asleep"
                     : "\(running) running session(s), \(busy) working"]
        if let down = model.coreConnectionDown { parts.append("core connection down: \(down)") }
        else if coreStale { parts.append("the daemon is stale") }
        if let buildWarning { parts.append(buildWarning.headline) }
        return parts.joined(separator: " · ")
    }
}
