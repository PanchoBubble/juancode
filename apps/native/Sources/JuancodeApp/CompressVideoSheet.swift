import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JuancodeDesktop

/// "Compress Video" tool (Tools popover): drop a screen recording on it and it becomes a
/// Slack-sized `<name> (slack).mp4` next to the original. The four toggles are the ones
/// that matter; their last values are remembered (`VideoCompressSettings`).
struct CompressVideoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case running(name: String, progress: Double?)
        case done(VideoCompressOutcome)
        case failed(String)
    }

    @State private var settings = VideoCompressSettings.load()
    @State private var phase: Phase = .idle
    /// The file the last run started from, so "Compress again" can reuse it with new toggles.
    @State private var lastInput: URL?
    @State private var job: VideoCompressJob?
    @State private var dropTargeted = false
    @State private var copiedPath = false

    private var running: Bool { if case .running = phase { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Compress Video").font(.title3).bold()
                Spacer()
                Button("Done") { job?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).clickCursor()
            }
            .padding()
            Divider()
            VStack(spacing: 14) {
                dropZone
                options
            }
            .padding(14)
        }
        .frame(width: 440)
        .onChange(of: settings) { _, new in new.save() }
    }

    // MARK: drop zone + states

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            content.padding(14)
        }
        .frame(height: 150)
        .contentShape(Rectangle())
        .onTapGesture { if !running { pickFile() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !running, let url = urls.first(where: { $0.isFileURL }) else { return false }
            start(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            prompt(icon: "film", title: "Drop a video here",
                   detail: "or click to choose — .mov .mp4 .m4v .webm .mkv")
        case .running(let name, let progress):
            VStack(spacing: 8) {
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if let progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { job?.cancel() }.clickCursor()
            }
        case .done(let outcome):
            VStack(spacing: 8) {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(Self.size(outcome.originalBytes)) → \(Self.size(outcome.compressedBytes))"
                     + " · \(Self.saved(outcome.savedFraction))")
                    .font(.system(size: 12))
                Text(outcome.output.lastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outcome.output])
                    }
                    Button(copiedPath ? "Copied" : "Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(outcome.output.path, forType: .string)
                        copiedPath = true
                    }
                    Button("Copy file") {
                        // A file on the pasteboard pastes into Slack as an upload.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([outcome.output as NSURL])
                    }
                }
                .controlSize(.small).clickCursor()
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 60)
                Button("Try another file") { pickFile() }.controlSize(.small).clickCursor()
            }
        }
    }

    private func prompt(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: toggles

    private var options: some View {
        VStack(spacing: 8) {
            optionRow("Max width", selection: $settings.maxWidth, cases: VideoCompressSettings.MaxWidth.allCases,
                      label: \.label, help: "Never upscales: a narrower video keeps its own width")
            optionRow("Quality", selection: $settings.quality, cases: VideoCompressSettings.Quality.allCases,
                      label: \.label, help: "Smaller = CRF 32, Balanced = 28, Sharper = 23")
            optionRow("FPS", selection: $settings.fps, cases: VideoCompressSettings.FPS.allCases,
                      label: \.label, help: "Never raises the frame rate above the source's")
            HStack {
                Text("Audio").font(.system(size: 12)).frame(width: 70, alignment: .leading)
                Picker("Audio", selection: $settings.keepAudio) {
                    Text("Keep").tag(true)
                    Text("Strip").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if case .done = phase, let lastInput {
                Button("Compress again with these settings") { start(lastInput) }
                    .controlSize(.small).clickCursor()
            }
        }
        .disabled(running)
    }

    private func optionRow<T: Hashable>(_ title: String, selection: Binding<T>, cases: [T],
                                        label: KeyPath<T, String>, help: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 70, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(cases, id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .help(help)
    }

    // MARK: actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = VideoCompressNaming.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a video to compress"
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    private func start(_ url: URL) {
        let job = VideoCompressJob(input: url, settings: settings)
        self.job = job
        lastInput = url
        copiedPath = false
        phase = .running(name: url.lastPathComponent, progress: nil)
        let name = url.lastPathComponent
        Task {
            do {
                let outcome = try await job.run { fraction in
                    Task { @MainActor in
                        // A late tick from a finished/cancelled job must not resurrect the bar.
                        if self.job === job, case .running = self.phase {
                            self.phase = .running(name: name, progress: fraction)
                        }
                    }
                }
                phase = .done(outcome)
            } catch VideoCompressError.cancelled {
                phase = .idle
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            if self.job === job { self.job = nil }
        }
    }

    // MARK: formatting

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func saved(_ fraction: Double) -> String {
        fraction >= 0 ? "\(Int((fraction * 100).rounded()))% saved"
                      : "\(Int((-fraction * 100).rounded()))% larger"
    }
}
