import Foundation
import Darwin
import JuancodeCore

// "Compress Video" tool (Tools popover): shrink a screen recording with ffmpeg until it
// is small enough to share on Slack.
//
// Everything here is UI-free so the toggles → ffmpeg argv mapping, the output naming and
// the progress parsing are unit-testable. The defaults reproduce the command that worked
// for the user (24.8 MB → 1.9 MB on a 47 s 3166×2212 60 fps recording):
//
//   ffmpeg -y -i IN -vf "scale=1920:-2,fps=30" -c:v libx264 -preset slow -crf 28
//          -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 96k OUT.mp4
//
// with two refinements the request asked for: never upscale (`min(1920,iw)`) and never
// raise the frame rate above the source's.

// MARK: - settings

/// The user's toggles. Persisted as JSON under `defaultsKey` so the last-used values come
/// back next time, like the Kill Port tool's saved ports.
public struct VideoCompressSettings: Codable, Equatable, Sendable {
    public enum MaxWidth: String, Codable, CaseIterable, Sendable {
        case w1280, w1920, original
        /// nil = keep the source width.
        public var pixels: Int? {
            switch self {
            case .w1280: 1280
            case .w1920: 1920
            case .original: nil
            }
        }
        public var label: String {
            switch self {
            case .w1280: "1280"
            case .w1920: "1920"
            case .original: "Original"
            }
        }
    }

    public enum Quality: String, Codable, CaseIterable, Sendable {
        case smaller, balanced, sharper
        /// x264 constant rate factor: higher = smaller file.
        public var crf: Int {
            switch self {
            case .smaller: 32
            case .balanced: 28
            case .sharper: 23
            }
        }
        public var label: String {
            switch self {
            case .smaller: "Smaller"
            case .balanced: "Balanced"
            case .sharper: "Sharper"
            }
        }
    }

    public enum FPS: String, Codable, CaseIterable, Sendable {
        case thirty, sixty, source
        /// nil = keep the source's frame rate.
        public var cap: Double? {
            switch self {
            case .thirty: 30
            case .sixty: 60
            case .source: nil
            }
        }
        public var label: String {
            switch self {
            case .thirty: "30"
            case .sixty: "60"
            case .source: "Source"
            }
        }
    }

    public var maxWidth: MaxWidth = .w1920
    public var quality: Quality = .balanced
    public var fps: FPS = .thirty
    /// true = keep the audio track (AAC 96k); false = strip it (`-an`).
    public var keepAudio: Bool = true

    public init(maxWidth: MaxWidth = .w1920, quality: Quality = .balanced,
                fps: FPS = .thirty, keepAudio: Bool = true) {
        self.maxWidth = maxWidth
        self.quality = quality
        self.fps = fps
        self.keepAudio = keepAudio
    }

    public static let defaultsKey = "juancode.compressVideo.settings"

    /// The saved settings, or the defaults when nothing (or nothing readable) is saved —
    /// a tool preference is not worth refusing to open over.
    public static func load(from defaults: UserDefaults = .standard) -> VideoCompressSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(VideoCompressSettings.self, from: data)
        else { return VideoCompressSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - probe

/// What `ffprobe` says about the source — the inputs the argument builder and the
/// progress bar need.
public struct VideoProbe: Equatable, Sendable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    /// Average frame rate (what the file actually delivers; a screen recording's `r_frame_rate`
    /// is its 60 Hz time base, not its real rate). nil when unknown.
    public var fps: Double?
    public var hasAudio: Bool

    public init(duration: Double? = nil, width: Int? = nil, height: Int? = nil,
                fps: Double? = nil, hasAudio: Bool = false) {
        self.duration = duration; self.width = width; self.height = height
        self.fps = fps; self.hasAudio = hasAudio
    }

    /// Parse `ffprobe -of json -show_entries stream=codec_type,width,height,r_frame_rate,
    /// avg_frame_rate:format=duration`.
    public static func parse(json: Data) -> VideoProbe? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let video = streams.first { ($0["codec_type"] as? String) == "video" }
        var probe = VideoProbe()
        probe.hasAudio = streams.contains { ($0["codec_type"] as? String) == "audio" }
        probe.width = video?["width"] as? Int
        probe.height = video?["height"] as? Int
        probe.fps = (video?["avg_frame_rate"] as? String).flatMap(parseRate)
            ?? (video?["r_frame_rate"] as? String).flatMap(parseRate)
        if let format = root["format"] as? [String: Any],
           let d = (format["duration"] as? String).flatMap(Double.init), d > 0 {
            probe.duration = d
        }
        return probe.width == nil && probe.duration == nil ? nil : probe
    }

    /// "27180/617" → 44.05; "0/0" and garbage → nil.
    static func parseRate(_ s: String) -> Double? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0, n > 0
        else { return Double(s).flatMap { $0 > 0 ? $0 : nil } }
        return n / d
    }
}

// MARK: - argument builder

public enum FFmpegArguments {
    /// The ffmpeg argv (without the executable) for `settings` over a source described by
    /// `probe`. `output` is whatever file ffmpeg should write — the caller writes to a
    /// partial name and renames, so `-f mp4` is explicit.
    public static func build(input: String, output: String, settings: VideoCompressSettings,
                             probe: VideoProbe) -> [String] {
        var filters = [scaleFilter(settings.maxWidth)]
        if let fps = fpsFilter(settings.fps, sourceFPS: probe.fps) { filters.append(fps) }

        var args = [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            // Machine-readable progress on stdout: key=value lines, `out_time_us=…` among them.
            "-nostats", "-progress", "pipe:1",
            "-y", "-i", input,
            "-vf", filters.joined(separator: ","),
            "-c:v", "libx264", "-preset", "slow", "-crf", String(settings.quality.crf),
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            // One video + one audio stream: a subtitle stream the default mapping would pick
            // up from an mkv cannot go into an mp4 as-is.
            "-sn", "-dn",
        ]
        if settings.keepAudio {
            args += ["-c:a", "aac", "-b:a", "96k"]
        } else {
            args += ["-an"]
        }
        args += ["-f", "mp4", output]
        return args
    }

    /// `-2` keeps the height even for yuv420p; the `min(…, iw)` keeps a narrow source
    /// from being upscaled; `trunc(iw/2)*2` keeps an odd source width even, because
    /// libx264 + yuv420p refuse an odd dimension. The quotes are ffmpeg's own filter-graph
    /// quoting (there is no shell), protecting the comma in `min()`.
    static func scaleFilter(_ width: VideoCompressSettings.MaxWidth) -> String {
        if let w = width.pixels { return "scale='min(\(w),trunc(iw/2)*2)':-2" }
        return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    /// The `fps` filter, or nil when the output should simply keep the source's rate:
    /// "source" always does, and a cap at or above the source's rate must never raise it.
    /// An unknown source rate is capped, since that can only ever lower it.
    static func fpsFilter(_ fps: VideoCompressSettings.FPS, sourceFPS: Double?) -> String? {
        guard let cap = fps.cap else { return nil }
        if let sourceFPS, sourceFPS <= cap + 0.01 { return nil }
        return "fps=\(Int(cap))"
    }
}

// MARK: - progress

/// Incremental parser for `-progress pipe:1`: feed it raw chunks (a line can be split
/// across two reads) and read back the encoded-so-far position in seconds.
public struct FFmpegProgressParser: Sendable {
    private var buffer = ""
    /// Seconds of output written so far.
    public private(set) var seconds: Double = 0
    public private(set) var finished = false

    public init() {}

    @discardableResult
    public mutating func feed(_ chunk: String) -> Double {
        buffer += chunk
        // Everything up to the last newline is whole lines; the tail waits for more bytes.
        guard let lastNewline = buffer.lastIndex(of: "\n") else { return seconds }
        let complete = buffer[..<lastNewline]
        buffer = String(buffer[buffer.index(after: lastNewline)...])
        for line in complete.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = line[line.index(after: eq)...]
            switch key {
            // `out_time_ms` is a long-standing misnomer: it is microseconds too.
            case "out_time_us", "out_time_ms":
                if let us = Double(value), us >= 0 { seconds = us / 1_000_000 }
            case "progress":
                if value == "end" { finished = true }
            default: break
            }
        }
        return seconds
    }

    /// 0…1, or nil when the duration is unknown.
    public func fraction(duration: Double?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, seconds / duration))
    }
}

// MARK: - output naming

public enum VideoCompressNaming {
    /// Extensions the tool accepts.
    public static let acceptedExtensions: Set<String> = ["mov", "mp4", "m4v", "webm", "mkv"]

    public static func accepts(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// `<dir>/<original name> (slack).mp4`, or `… (slack) 2.mp4`, `… 3.mp4` when that
    /// exists. `exists` is injected so the rule is testable without a filesystem.
    public static func outputURL(for input: URL, exists: (URL) -> Bool) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem) (slack).mp4")
        var n = 2
        while exists(candidate) {
            candidate = dir.appendingPathComponent("\(stem) (slack) \(n).mp4")
            n += 1
        }
        return candidate
    }
}

// MARK: - the job

public struct VideoCompressOutcome: Equatable, Sendable {
    public let output: URL
    public let originalBytes: Int64
    public let compressedBytes: Int64

    /// Fraction of the original that was saved (negative if the output grew).
    public var savedFraction: Double {
        originalBytes > 0 ? 1 - Double(compressedBytes) / Double(originalBytes) : 0
    }
}

public enum VideoCompressError: LocalizedError, Equatable {
    case unsupported(String)
    case ffmpegMissing
    case probeFailed(String)
    case ffmpegFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            "Unsupported file type “.\(ext)”. Drop a .mov, .mp4, .m4v, .webm or .mkv video."
        case .ffmpegMissing:
            "ffmpeg was not found. Install it with “brew install ffmpeg” and try again."
        case .probeFailed(let why):
            "Could not read the video: \(why)"
        case .ffmpegFailed(let why):
            "ffmpeg failed: \(why)"
        case .cancelled:
            "Cancelled."
        }
    }
}

/// One compression run. `run` probes, encodes to a hidden partial file next to the source,
/// then renames it to its final `(slack).mp4` name — so a cancel or a failure never leaves
/// a half-written file under the real name, and the original is only ever read.
public final class VideoCompressJob: @unchecked Sendable {
    public let input: URL
    public let settings: VideoCompressSettings

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(input: URL, settings: VideoCompressSettings) {
        self.input = input
        self.settings = settings
    }

    /// Stop ffmpeg. Safe from any thread, before or during `run`.
    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        // SIGTERM makes ffmpeg stop cleanly; `run` then deletes the partial output.
        if let p, p.isRunning { p.terminate() }
    }

    private func clearProcess() { lock.lock(); process = nil; lock.unlock() }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// `onProgress` receives 0…1 (not called when the duration is unknown) from a
    /// background thread.
    public func run(onProgress: @escaping @Sendable (Double) -> Void) async throws -> VideoCompressOutcome {
        try await withTaskCancellationHandler {
            try await perform(onProgress: onProgress)
        } onCancel: {
            self.cancel()
        }
    }

    private func perform(onProgress: @escaping @Sendable (Double) -> Void) async throws -> VideoCompressOutcome {
        guard VideoCompressNaming.accepts(input) else {
            throw VideoCompressError.unsupported(input.pathExtension)
        }
        let fm = FileManager.default
        guard let originalBytes = Self.fileSize(input) else {
            throw VideoCompressError.probeFailed("the file cannot be read")
        }

        // `locateBin` may spawn a login shell on a Finder launch; keep it off the caller's thread.
        let tools = await Task.detached { Self.locateTools() }.value
        guard let tools else { throw VideoCompressError.ffmpegMissing }
        if isCancelled { throw VideoCompressError.cancelled }

        let probe = try await Self.probe(ffprobe: tools.ffprobe, input: input)
        if isCancelled { throw VideoCompressError.cancelled }

        // Encode to a hidden sibling and rename: the final name only ever holds a finished file.
        let partial = input.deletingLastPathComponent()
            .appendingPathComponent(".\(input.deletingPathExtension().lastPathComponent).\(UUID().uuidString).slack-partial")
        defer { try? fm.removeItem(at: partial) }

        let args = FFmpegArguments.build(input: input.path, output: partial.path,
                                         settings: settings, probe: probe)
        try await encode(ffmpeg: tools.ffmpeg, args: args, duration: probe.duration, onProgress: onProgress)
        if isCancelled { throw VideoCompressError.cancelled }

        let output = try Self.place(partial, nextTo: input)
        let compressedBytes = Self.fileSize(output) ?? 0
        onProgress(1)
        return VideoCompressOutcome(output: output, originalBytes: originalBytes, compressedBytes: compressedBytes)
    }

    // MARK: pieces

    static func fileSize(_ url: URL) -> Int64? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// ffmpeg and ffprobe, resolved like every other CLI the app shells out to (inherited
    /// PATH, login shell, Homebrew dirs). nil when either is missing.
    public static func locateTools() -> (ffmpeg: String, ffprobe: String)? {
        guard let ffmpeg = locateBin("ffmpeg", override: ProcessInfo.processInfo.environment["JUANCODE_FFMPEG_BIN"]),
              let ffprobe = locateBin("ffprobe", override: ProcessInfo.processInfo.environment["JUANCODE_FFPROBE_BIN"])
        else { return nil }
        return (ffmpeg, ffprobe)
    }

    static func probe(ffprobe: String, input: URL) async throws -> VideoProbe {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.capture(ffprobe, [
                "-v", "error", "-of", "json",
                "-show_entries", "stream=codec_type,width,height,r_frame_rate,avg_frame_rate:format=duration",
                input.path,
            ], timeout: 30)
        } catch let e as ProcessError {
            throw VideoCompressError.probeFailed(e.message)
        }
        guard result.ok, let probe = VideoProbe.parse(json: Data(result.stdout.utf8)) else {
            let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VideoCompressError.probeFailed(why.isEmpty ? "not a readable video" : why)
        }
        return probe
    }

    /// Move the finished partial to its final name without ever replacing a file: the name is
    /// chosen against what exists, and `moveItem` itself refuses an existing destination, so a
    /// file that appears in between just bumps the suffix.
    static func place(_ partial: URL, nextTo input: URL) throws -> URL {
        let fm = FileManager.default
        var lastError: Error = VideoCompressError.ffmpegFailed("could not write the output file")
        for _ in 0..<20 {
            let target = VideoCompressNaming.outputURL(for: input) { fm.fileExists(atPath: $0.path) }
            do {
                try fm.moveItem(at: partial, to: target)
                return target
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                lastError = e
            } catch {
                throw VideoCompressError.ffmpegFailed("could not write the output file: \(error.localizedDescription)")
            }
        }
        throw VideoCompressError.ffmpegFailed("could not pick a free output name: \(lastError.localizedDescription)")
    }

    private func encode(ffmpeg: String, args: [String], duration: Double?,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        // `environment` stays nil: the child inherits ours untouched, like ProcessRunner.
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let state = EncodeState()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let fraction = state.feedProgress(String(decoding: chunk, as: UTF8.self), duration: duration) {
                onProgress(fraction)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            state.appendStderr(chunk)
        }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { p in
                // The pipes can still hold bytes the handlers have not seen; drain them so the
                // error text is complete, then close our read ends (no fd leak).
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if let rest = try? err.fileHandleForReading.readToEnd() { state.appendStderr(rest) }
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
                cont.resume(returning: p.terminationStatus)
            }
            lock.lock()
            if cancelled { lock.unlock(); cont.resume(throwing: VideoCompressError.cancelled); return }
            process = proc
            lock.unlock()
            do {
                try proc.run()
            } catch {
                lock.lock(); process = nil; lock.unlock()
                // `terminationHandler` never fires for a process that did not start.
                cont.resume(throwing: VideoCompressError.ffmpegFailed("could not launch ffmpeg: \(error.localizedDescription)"))
                return
            }
            // Drop our write ends so the read ends can EOF.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            // A cancel that landed between the check above and `run()` found a process that
            // was not running yet and did nothing; honour it now.
            lock.lock(); let late = cancelled; lock.unlock()
            if late { proc.terminate() }
        }
        clearProcess()

        if isCancelled { throw VideoCompressError.cancelled }
        guard status == 0 else {
            throw VideoCompressError.ffmpegFailed(state.stderrTail.isEmpty ? "exit code \(status)" : state.stderrTail)
        }
    }

    /// Progress parser + stderr tail, shared between the two pipe handlers.
    private final class EncodeState: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = FFmpegProgressParser()
        private var stderr = Data()

        func feedProgress(_ chunk: String, duration: Double?) -> Double? {
            lock.lock(); defer { lock.unlock() }
            parser.feed(chunk)
            return parser.fraction(duration: duration)
        }

        func appendStderr(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            stderr.append(data)
            if stderr.count > 8192 { stderr = stderr.suffix(8192) }
        }

        var stderrTail: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
