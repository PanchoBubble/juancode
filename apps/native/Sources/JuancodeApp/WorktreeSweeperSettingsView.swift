// Settings → Worktrees pane (juancode-ailq): read a dry run, then decide whether the
// daily sweeper is allowed to remove anything.
//
// The order of the pane is the argument it makes. The preview is first and it is the
// only control that is enabled the moment the pane opens; installing the daily job is
// second; letting that job actually remove things is third and stays disabled until a
// dry run has been read in this window. An armed sweeper nobody has watched run once
// deletes on a schedule, and the first anyone hears about it is a worktree that is
// gone.
//
// Nothing about safety is decided here. Every verdict comes from
// `scripts/worktree-sweep.mjs`, the schedule comes from
// `apps/native/scripts/worktree-sweeper-agent.sh`, and this pane shells out to both
// (see `WorktreeSweeper.swift`). There is deliberately no --force, no "remove anyway",
// and no way to run an --apply sweep other than the daily job: the script's refusals
// are the whole safety model and a UI that could talk it round would be worse than no
// UI at all.

import AppKit
import SwiftUI
import JuancodeDesktop
import JuancodeServices

struct WorktreeSweeperSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sweeper = WorktreeSweeperState()

    /// Draft age floor, kept separate from what is installed so switching the daily
    /// job off and on again doesn't lose the chosen number (the pattern
    /// `SessionSettingsView` uses for its sleep duration).
    @AppStorage("worktreeSweepDays") private var days = 2

    @State private var confirmArm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Worktrees").font(.headline)
                Spacer()
                if sweeper.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let checkout = sweeper.paths?.mainCheckout {
                        Text(checkout)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.head)
                    } else {
                        Label(WorktreeSweeperError.noCheckout.localizedDescription,
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ageFloor
                    Divider().padding(.vertical, 4)
                    previewSection
                    Divider().padding(.vertical, 4)
                    scheduleSection
                    Divider().padding(.vertical, 4)
                    lastRunSection

                    if let error = sweeper.error {
                        Text(error)
                            .font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            Divider()
            Text("The sweep removes a working directory and nothing else — the branch "
                + "and its commits survive, so a tree removed by mistake can be made "
                + "again with `git worktree add`. A tree with uncommitted files, "
                + "unpushed commits, an open PR, or anything running inside it is never "
                + "removed, and this pane has no override for that.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 560, height: 620)
        .task { await sweeper.load(hints: Array(Set(model.worktreeRepoRoots.values))) }
    }

    // MARK: - age floor

    private var ageFloor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Sweep worktrees older than")
                Stepper(value: $days, in: 1...60) {
                    Text("\(days) day\(days == 1 ? "" : "s")").monospacedDigit()
                }
                .fixedSize()
            }
            if sweeper.status.installed, !sweeper.status.days.isEmpty,
               sweeper.status.days != String(days) {
                HStack(spacing: 8) {
                    Text("The scheduled job still uses \(sweeper.status.days) days.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Update it") { Task { await sweeper.reinstall(days: days) } }
                        .controlSize(.small).clickCursor()
                }
            }
        }
    }

    // MARK: - preview (the first thing anyone should do)

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await sweeper.preview(days: days) }
                } label: {
                    Label("Preview a sweep", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .disabled(sweeper.busy || sweeper.paths == nil)
                .clickCursor()

                if sweeper.previewing {
                    ProgressView().controlSize(.small)
                    Text("walking every worktree — this takes a couple of minutes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("A dry run. It changes nothing: it lists every worktree of this "
                + "checkout with the verdict the daily job would reach.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = sweeper.preview {
                previewSummary(preview)
                verdictTable(preview)
            }
        }
    }

    private func previewSummary(_ preview: WorktreeSweepPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(preview.rows.count) worktrees")
                Text("·")
                Text("\(preview.wouldRemove.count) would be removed")
                    .foregroundStyle(preview.wouldRemove.isEmpty ? Color.secondary : Color.red)
                Text("·")
                Text("\(preview.kept.count) kept").foregroundStyle(.secondary)
                if let freed = sweeper.reclaimable {
                    Text("·")
                    Text("\(WorktreeSweeper.formatSize(freed)) freed").foregroundStyle(.secondary)
                } else if sweeper.sizing {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)

            if let blocked = preview.blockedReason {
                Label(blocked, systemImage: "bolt.horizontal.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gh = preview.ghWarning {
                Text(gh).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Would-remove first: those are the rows the decision is about.
    private func verdictTable(_ preview: WorktreeSweepPreview) -> some View {
        let rows = preview.wouldRemove + preview.kept
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                verdictRow(row)
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func verdictRow(_ row: WorktreeSweepRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.willRemove ? "remove" : "keep")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.willRemove ? Color.red : Color.secondary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.short).font(.system(size: 11, design: .monospaced))
                Text("\(row.code) · \(row.reason)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(sweeper.sizes[row.path].map(WorktreeSweeper.formatSize) ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(row.ageLabel)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .help(row.path)
    }

    // MARK: - the daily job

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Run a daily sweep", isOn: Binding(
                get: { sweeper.status.installed },
                set: { on in Task { await sweeper.setInstalled(on, days: days) } }))
                .disabled(sweeper.busy || sweeper.paths == nil)

            Text("Installs a LaunchAgent that runs once a day at 04:30. It is installed "
                + "as a dry run: it writes the log and removes nothing until the switch "
                + "below. Turning this off boots the job out and deletes the plist.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Let the daily run actually remove worktrees", isOn: Binding(
                get: { sweeper.status.armed },
                set: { on in
                    if on { confirmArm = true } else { Task { await sweeper.setArmed(false) } }
                }))
                .disabled(sweeper.busy || !sweeper.status.installed || !canArm)
                .foregroundStyle(canArm && sweeper.status.installed ? .primary : .secondary)

            Text(armHint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let other = sweeper.status.otherCheckout {
                Label("The installed job sweeps another checkout: \(other)",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Arm the daily sweep?", isPresented: $confirmArm) {
            Button("Cancel", role: .cancel) {}
            Button("Arm it", role: .destructive) { Task { await sweeper.setArmed(true) } }
        } message: {
            Text("From tomorrow at 04:30 the job will remove the worktrees the preview "
                + "marked \"remove\", re-checking each one immediately before it goes. "
                + "Branches and commits are never deleted, only working directories.")
        }
    }

    /// Arming is gated on having read a dry run in this window, and on that dry run
    /// having found both liveness sources answering — a sweep that cannot see what is
    /// running would not remove anything anyway.
    private var canArm: Bool {
        sweeper.status.armed || (sweeper.preview?.couldRemove ?? false)
    }

    private var armHint: String {
        if !sweeper.status.installed { return "Install the daily job first." }
        if sweeper.status.armed { return "Armed. Switch it off to go back to a dry run that only logs." }
        guard let preview = sweeper.preview else {
            return "Read a preview first — this switch stays off until you have."
        }
        if let blocked = preview.blockedReason { return blocked }
        return "Nothing removes a worktree until this is on."
    }

    // MARK: - what it did last

    private var lastRunSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last run").font(.subheadline).bold()
                Spacer()
                Button("Reveal log") { sweeper.revealLog() }
                    .controlSize(.small).clickCursor()
                    .disabled(!FileManager.default.fileExists(atPath: sweeper.logPath))
            }
            if let run = sweeper.lastRun {
                Text("\(run.mode) · \(sweeper.lastRunWhen) · \(run.trees) worktrees · "
                    + "\(run.removed) removed · \(run.wouldRemove) would have been · \(run.kept) kept")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if run.daemonUnreachable {
                    Text("The daemon was unreachable, so that run removed nothing.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(run.removedPaths, id: \.self) { path in
                    Text(path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if run.removed > 0 {
                    Text("The log records what went, not how much space came back.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text("No run yet. \(sweeper.logPath)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }
}

// MARK: - state

/// Everything the pane shells out for. Kept off the view so the async work survives a
/// re-render, and so `WorktreeSweeper`'s parsers stay the only thing that needs testing.
@MainActor
@Observable
final class WorktreeSweeperState {
    /// Built as a `@State` default, which is evaluated outside the main actor.
    nonisolated init() {}

    private(set) var paths: WorktreeSweeperPaths?
    private(set) var status = WorktreeSweeperStatus.notInstalled
    private(set) var preview: WorktreeSweepPreview?
    private(set) var sizes: [String: Int64] = [:]
    private(set) var lastRun: WorktreeSweepLastRun?
    private(set) var previewing = false
    private(set) var sizing = false
    private(set) var working = false
    var error: String?

    var busy: Bool { previewing || working }

    /// Bytes the previewed run would free, once the sizes are in.
    var reclaimable: Int64? {
        guard let preview, !preview.wouldRemove.isEmpty else { return nil }
        let known = preview.wouldRemove.compactMap { sizes[$0.path] }
        guard known.count == preview.wouldRemove.count else { return nil }
        return known.reduce(0, +)
    }

    var lastRunWhen: String {
        guard let run = lastRun else { return "never" }
        guard let date = run.startedAt else { return run.startedAtRaw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A preview walks every worktree, runs `git status` in each and samples the whole
    /// process table; the run measured while building this pane took over two minutes.
    private let previewTimeout: TimeInterval = 900
    private let installTimeout: TimeInterval = 60

    /// Where the run log actually is: what the installer reports, then what a
    /// preview reported, then the script's own default. Never `Config.logDir` —
    /// the sweep runs from launchd and reads `JUANCODE_LOG_DIR` alone.
    var logPath: String {
        if !status.runLog.isEmpty { return status.runLog }
        return preview?.logFile ?? WorktreeSweeper.logFile
    }

    func load(hints: [String]) async {
        paths = WorktreeSweeper.locate(hints: hints)
        await refreshStatus()
        readLog()
    }

    func readLog() {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        lastRun = WorktreeSweeper.parseLastRun(log: text)
    }

    func refreshStatus() async {
        guard let paths else { return }
        working = true
        defer { working = false }
        do {
            // `status` reports through stderr, like the rest of the script's prose.
            let result = try await WorktreeSweeper.run(
                paths, ["status"], days: nil, timeout: installTimeout)
            status = WorktreeSweeper.parseStatus(result.stderr + "\n" + result.stdout)
        } catch {
            self.error = "worktree-sweeper status: \(error.localizedDescription)"
        }
    }

    func preview(days: Int) async {
        guard let paths else { error = WorktreeSweeperError.noCheckout.localizedDescription; return }
        previewing = true
        error = nil
        sizes = [:]
        defer { previewing = false }
        do {
            let result = try await WorktreeSweeper.run(
                paths, ["run", "--json"], days: days, timeout: previewTimeout)
            // A non-zero exit means a removal failed mid-sweep; a dry run still prints
            // its verdicts, so decode first and only complain if there is nothing to read.
            do {
                preview = try WorktreeSweeper.decodePreview(result.stdout)
            } catch {
                throw WorktreeSweeperError.script(
                    result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? error.localizedDescription
                        : result.stderr)
            }
            readLog()
            await measureSizes()
        } catch {
            self.error = "preview failed: \(error.localizedDescription)"
        }
    }

    /// One `du` for every worktree at once: spawning is expensive on this machine, and
    /// this is display only — no verdict depends on it.
    func measureSizes() async {
        guard let preview, !preview.rows.isEmpty else { return }
        sizing = true
        defer { sizing = false }
        let paths = preview.rows.map(\.path)
        if let result = try? await ProcessRunner.capture(
            "/usr/bin/du", ["-sk", "-x"] + paths, timeout: previewTimeout) {
            sizes = WorktreeSweeper.parseDiskUsage(result.stdout)
        }
    }

    func setInstalled(_ on: Bool, days: Int) async {
        await runInstaller(on ? ["install"] : ["uninstall"], days: days)
    }

    func reinstall(days: Int) async {
        // Rewriting the plist keeps whatever decision is already in force; it is not
        // the moment to arm or disarm anything.
        await runInstaller(status.armed ? ["install", "--apply"] : ["install"],
                           days: days, confirmArming: status.armed)
    }

    func setArmed(_ on: Bool) async {
        await runInstaller(on ? ["arm"] : ["disarm"], days: nil, confirmArming: on)
    }

    private func runInstaller(_ args: [String], days: Int?, confirmArming: Bool = false) async {
        guard let paths else { error = WorktreeSweeperError.noCheckout.localizedDescription; return }
        working = true
        error = nil
        defer { working = false }
        do {
            let result = try await WorktreeSweeper.run(
                paths, args, days: days, confirmArming: confirmArming, timeout: installTimeout)
            if !result.ok {
                error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            self.error = "worktree-sweeper \(args.joined(separator: " ")): \(error.localizedDescription)"
        }
        await refreshStatus()
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logPath)])
    }
}
