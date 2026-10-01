// The toolbar's waiting-input badge: how many agents are sitting on a question, a
// choice or a permission prompt, and the list behind it to jump to each one.
//
// At zero it stays in place, dimmed and without a number, like the GitHub queue
// badge: a toolbar slot that appears and disappears shifts its neighbours under
// the pointer.

import SwiftUI
import JuancodeCore

struct WaitingInputBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    /// Off the model's stored projection, never a filter over `activities`: this
    /// body must not re-run on every busy↔idle edge (juancode-2n0).
    private var waiting: [WaitingSessions.Entry] { model.waitingSessions }

    private var badgeLabel: String {
        waiting.isEmpty ? "No sessions waiting on you" : "\(waiting.count) session(s) waiting on you"
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: waiting.isEmpty ? "questionmark.bubble" : "questionmark.bubble.fill")
                if !waiting.isEmpty {
                    Text("\(waiting.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .accessibilityLabel(badgeLabel)
        }
        .foregroundStyle(waiting.isEmpty ? Color.secondary : Color.yellow)
        .help(badgeLabel)
        .clickCursor()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            WaitingInputPopover(showing: $showing)
                .frame(width: 300)
        }
    }
}

private struct WaitingInputPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var showing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Waiting on you").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if model.waitingSessions.isEmpty {
                Text("Nothing is waiting for input.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            } else {
                // A once-a-second clock for the "waiting 4m" labels, scoped to the
                // popover so a closed badge never ticks.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.waitingSessions) { entry in
                            row(entry, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func row(_ entry: WaitingSessions.Entry, now: Date) -> some View {
        if let meta = model.sessions.first(where: { $0.id == entry.id }) {
            Button {
                // `revealSession`, not a bare selection: an Oracle row is never the
                // sidebar selection, so setting it would look like a dead click.
                model.revealSession(entry.id)
                showing = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meta.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text((meta.cwd as NSString).lastPathComponent)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let since = entry.since {
                        Text(WaitingSessions.elapsed(since: since, now: now))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .clickCursor()
        }
    }
}
