import SwiftUI
import JuancodeCore
import AppKit
import JuancodeServices

/// The global heavy-command queue (juancode-ik11): memory-heavy commands — pandora
/// CI, integration tests — serialized across every Claude session on this Mac by
/// `~/.claude/bin/heavy`.
///
/// Shows what holds the slots, who is waiting and in what order, and lets you
/// reorder the line (move to front, nudge up/down), cancel a job, or widen the queue
/// by adding slots. Reordering is a priority rewrite in the shared registry; the
/// waiting wrappers pick it up on their next poll (~3s), so nothing here has to talk
/// to those processes directly.
struct HeavyQueuePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Ticks the relative times ("4m ago") without a full reload every second.
    @State private var now = Date()

    private var queue: HeavyQueueSnapshot { model.heavyQueue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if queue.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        section("Running", count: queue.running.count)
                        ForEach(queue.running) { job in
                            HeavyJobRow(job: job, position: nil, now: now,
                                        canMoveUp: false, canMoveDown: false)
                            Divider()
                        }
                        if !queue.waiting.isEmpty {
                            section("Waiting", count: queue.waiting.count)
                            ForEach(Array(queue.waiting.enumerated()), id: \.element.id) { i, job in
                                HeavyJobRow(job: job, position: i + 1, now: now,
                                            canMoveUp: i > 0,
                                            canMoveDown: i < queue.waiting.count - 1)
                                Divider()
                            }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 460)
        .onAppear { model.refreshHeavyQueue() }
        // Poll: the queue is other processes' state, so there's nothing to observe.
        .task {
            while !Task.isCancelled {
                await Nap.duration(.seconds(2))
                now = Date()
                model.refreshHeavyQueue()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Heavy Queue").font(.title3).bold()
            Text("\(queue.running.count)/\(queue.slots) running")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { model.refreshHeavyQueue() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reload the queue").clickCursor()
            Button("Done") { dismiss() }.clickCursor()
        }
        .padding()
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing queued.").foregroundStyle(.secondary).font(.system(size: 13))
            Text("Memory-heavy commands (CI, integration tests) run through a shared\nslot queue so two sessions never run them at once. Anything queued\nby `heavy` shows up here, in the order it will run.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Slots").font(.system(size: 11)).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { queue.slots },
                set: { HeavyQueue.shared.setSlots($0); model.refreshHeavyQueue() }
            ), in: 1...8) {
                Text("\(queue.slots)").font(.system(size: 11).monospacedDigit())
            }
            .help("How many heavy jobs may run at once. Each one can use several GB — "
                + "raising this is how you trade RAM for throughput.")
            Text("· worker cap \(queue.workerCap)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("Test-runner workers each queued job may fan out to (VITEST_MAX_THREADS et al)")
            Spacer()
            Text("~/.claude/heavy-queue.json")
                .font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }
}

/// One job: what it runs, where, how long it's been running or waiting, and the
/// actions available on it. Waiting rows carry their place in line and the reorder
/// controls; running rows only offer a cancel.
private struct HeavyJobRow: View {
    @Environment(AppModel.self) private var model
    let job: HeavyJob
    /// 1-based place in the waiting line; nil for a running job.
    let position: Int?
    let now: Date
    let canMoveUp: Bool
    let canMoveDown: Bool
    @State private var confirmingCancel = false

    var body: some View {
        HStack(spacing: 10) {
            if let position {
                Text("\(position)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 18)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11)).foregroundStyle(.green).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(job.cmd)
                    .font(.system(size: 12).monospaced()).lineLimit(1)
                    .truncationMode(.middle).help(job.cmd)
                HStack(spacing: 8) {
                    if !job.project.isEmpty {
                        Text(job.project).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .help(job.cwd)
                    }
                    Text(timing).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("pid \(job.pid)").font(.system(size: 10)).foregroundStyle(.quaternary)
                }
            }
            Spacer(minLength: 8)
            if job.prio != 0 { tag("prio \(job.prio)", .blue) }
            if position != nil { reorderControls }
            Button(role: .destructive) { confirmingCancel = true } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(job.running ? "Stop this job and free its slot" : "Drop this job from the queue")
            .clickCursor()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .confirmationDialog(
            job.running ? "Stop this running job?" : "Drop this job from the queue?",
            isPresented: $confirmingCancel, titleVisibility: .visible
        ) {
            Button(job.running ? "Stop Job" : "Drop Job", role: .destructive) {
                model.cancelHeavyJob(job.pid)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(job.running
                 ? "Sends SIGTERM to the command and frees its slot. The session that started it sees the command fail.\n\n\(job.cmd)"
                 : "The waiting session gets an error instead of its turn.\n\n\(job.cmd)")
        }
    }

    private var reorderControls: some View {
        HStack(spacing: 2) {
            Button { model.heavyQueueMoveToFront(job.pid) } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .buttonStyle(.borderless).disabled(!canMoveUp)
            .help("Run this next").clickCursor()
            Button { model.heavyQueueNudge(job.pid, up: true) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless).disabled(!canMoveUp)
            .help("Move up one place").clickCursor()
            Button { model.heavyQueueNudge(job.pid, up: false) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless).disabled(!canMoveDown)
            .help("Move down one place").clickCursor()
        }
    }

    /// "running 4m" / "waiting 12s" — the number that tells you whether to intervene.
    private var timing: String {
        let start = job.running ? (job.started ?? job.since) : job.since
        guard start > 0 else { return job.running ? "running" : "waiting" }
        let elapsed = max(0, Int(now.timeIntervalSince1970) - start)
        return "\(job.running ? "running" : "waiting") \(shortDuration(elapsed))"
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// Compact elapsed-time label: 45s, 12m, 1h20m.
private func shortDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return m == 0 ? "\(h)h" : "\(h)h\(m)m"
}
