import Foundation
import Testing
import JuancodeCore
@testable import JuancodeDesktop

@Suite struct VideoCompressTests {
    private let screenRecording = VideoProbe(duration: 47, width: 3166, height: 2212, fps: 60, hasAudio: false)

    private func args(_ settings: VideoCompressSettings = .init(), probe: VideoProbe? = nil) -> [String] {
        FFmpegArguments.build(input: "in.mov", output: "out.mp4", settings: settings,
                              probe: probe ?? screenRecording)
    }

    /// The value following `flag` in an argv.
    private func value(of flag: String, in argv: [String]) -> String? {
        argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    // MARK: argument builder

    @Test func defaultsReproduceTheCommandThatWorked() {
        let argv = args()
        #expect(value(of: "-vf", in: argv) == "scale='min(1920,trunc(iw/2)*2)':-2,fps=30")
        #expect(value(of: "-c:v", in: argv) == "libx264")
        #expect(value(of: "-preset", in: argv) == "slow")
        #expect(value(of: "-crf", in: argv) == "28")
        #expect(value(of: "-pix_fmt", in: argv) == "yuv420p")
        #expect(value(of: "-movflags", in: argv) == "+faststart")
        #expect(value(of: "-c:a", in: argv) == "aac")
        #expect(value(of: "-b:a", in: argv) == "96k")
        #expect(!argv.contains("-an"))
        #expect(value(of: "-i", in: argv) == "in.mov")
        #expect(argv.last == "out.mp4")
    }

    @Test func widthQualityAndAudioTogglesMapToArguments() {
        // A 120 fps source, so the 60 cap really is a cap.
        let fast = VideoProbe(duration: 5, width: 3166, height: 2212, fps: 120, hasAudio: false)
        let small = args(.init(maxWidth: .w1280, quality: .smaller, fps: .sixty, keepAudio: false), probe: fast)
        #expect(value(of: "-vf", in: small) == "scale='min(1280,trunc(iw/2)*2)':-2,fps=60")
        #expect(value(of: "-crf", in: small) == "32")
        #expect(small.contains("-an"))
        #expect(!small.contains("-c:a"))

        let sharp = args(.init(maxWidth: .original, quality: .sharper, fps: .source, keepAudio: true))
        // Original width and source fps: only the even-dimension scale remains.
        #expect(value(of: "-vf", in: sharp) == "scale=trunc(iw/2)*2:trunc(ih/2)*2")
        #expect(value(of: "-crf", in: sharp) == "23")
    }

    @Test func neverRaisesTheFrameRateAboveTheSource() {
        // A 24 fps source asked for 30 keeps its 24: no fps filter at all.
        let film = VideoProbe(duration: 10, width: 1280, height: 720, fps: 24, hasAudio: true)
        #expect(value(of: "-vf", in: args(.init(), probe: film)) == "scale='min(1920,trunc(iw/2)*2)':-2")
        // A variable-rate recording averaging 44 fps asked for 60 is left alone, asked for 30 is capped.
        let vfr = VideoProbe(duration: 10, width: 3166, height: 2212, fps: 44.05, hasAudio: false)
        #expect(!(value(of: "-vf", in: args(.init(fps: .sixty), probe: vfr)) ?? "").contains("fps="))
        #expect((value(of: "-vf", in: args(.init(fps: .thirty), probe: vfr)) ?? "").hasSuffix(",fps=30"))
        // Unknown source rate: a cap can only lower it, so it stays.
        let unknown = VideoProbe(duration: nil, width: nil, height: nil, fps: nil, hasAudio: false)
        #expect((value(of: "-vf", in: args(.init(), probe: unknown)) ?? "").hasSuffix(",fps=30"))
    }

    @Test func reportsProgressOnStdoutAndWritesAnMp4Container() {
        let argv = args()
        #expect(value(of: "-progress", in: argv) == "pipe:1")
        #expect(value(of: "-f", in: argv) == "mp4")
        // Never reads the terminal.
        #expect(argv.contains("-nostdin"))
    }

    // MARK: probe

    @Test func parsesFfprobeJson() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","width":3166,"height":2212,"r_frame_rate":"60/1","avg_frame_rate":"27180/617"},
          {"codec_type":"audio"}],
         "format":{"duration":"61.470000"}}
        """
        let probe = try #require(VideoProbe.parse(json: Data(json.utf8)))
        #expect(probe.width == 3166 && probe.height == 2212)
        #expect(probe.duration == 61.47)
        #expect(probe.hasAudio)
        // The average rate, not the 60 Hz time base.
        #expect(abs(try #require(probe.fps) - 44.05) < 0.01)
    }

    @Test func fallsBackToTheTimeBaseWhenTheAverageRateIsUnknown() throws {
        let json = #"{"streams":[{"codec_type":"video","width":640,"height":360,"r_frame_rate":"30/1","avg_frame_rate":"0/0"}],"format":{"duration":"2.0"}}"#
        let probe = try #require(VideoProbe.parse(json: Data(json.utf8)))
        #expect(probe.fps == 30)
        #expect(!probe.hasAudio)
        #expect(VideoProbe.parse(json: Data("not json".utf8)) == nil)
    }

    // MARK: progress

    @Test func progressParsesLinesSplitAcrossReads() {
        var parser = FFmpegProgressParser()
        parser.feed("frame=10\nout_time_us=1500")
        #expect(parser.seconds == 0) // the line is incomplete
        parser.feed("000\nprogress=continue\nout_time_us=3000000\n")
        #expect(parser.seconds == 3)
        #expect(!parser.finished)
        #expect(parser.fraction(duration: 12) == 0.25)
        #expect(parser.fraction(duration: nil) == nil)
        parser.feed("out_time_us=N/A\nprogress=end\n")
        #expect(parser.finished)
        #expect(parser.seconds == 3) // "N/A" does not reset it
        // Overshoot (muxer rounding) never reports past 100%.
        #expect(parser.fraction(duration: 2) == 1)
    }

    // MARK: naming

    @Test func outputSitsNextToTheSourceAndNeverReusesAName() {
        let input = URL(fileURLWithPath: "/Users/x/Desktop/Screen Recording 1.mov")
        let first = VideoCompressNaming.outputURL(for: input) { _ in false }
        #expect(first.path == "/Users/x/Desktop/Screen Recording 1 (slack).mp4")
        let taken: Set<String> = [first.path, "/Users/x/Desktop/Screen Recording 1 (slack) 2.mp4"]
        let third = VideoCompressNaming.outputURL(for: input) { taken.contains($0.path) }
        #expect(third.path == "/Users/x/Desktop/Screen Recording 1 (slack) 3.mp4")
    }

    @Test func acceptsOnlyTheListedVideoTypes() {
        for ext in ["mov", "MP4", "m4v", "webm", "mkv"] {
            #expect(VideoCompressNaming.accepts(URL(fileURLWithPath: "/a/b.\(ext)")))
        }
        #expect(!VideoCompressNaming.accepts(URL(fileURLWithPath: "/a/b.png")))
        #expect(!VideoCompressNaming.accepts(URL(fileURLWithPath: "/a/b")))
    }

    // MARK: persistence

    @Test func lastUsedTogglesComeBackAndABadBlobFallsBackToDefaults() throws {
        let suite = "VideoCompressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VideoCompressSettings.load(from: defaults) == VideoCompressSettings())
        let chosen = VideoCompressSettings(maxWidth: .w1280, quality: .sharper, fps: .source, keepAudio: false)
        chosen.save(to: defaults)
        #expect(VideoCompressSettings.load(from: defaults) == chosen)
        defaults.set(Data("garbage".utf8), forKey: VideoCompressSettings.defaultsKey)
        #expect(VideoCompressSettings.load(from: defaults) == VideoCompressSettings())
    }

    // MARK: real ffmpeg (skipped where it is not installed)

    private static var ffmpegAvailable: Bool { VideoCompressJob.locateTools() != nil }

    /// End to end on a generated clip: the original is untouched, the output lands beside it
    /// under the `(slack)` name, a second run takes the next suffix instead of overwriting, and
    /// no partial file is left behind.
    @Test(.enabled(if: VideoCompressTests.ffmpegAvailable))
    func compressesNextToTheSourceWithoutTouchingItOrOverwriting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCompressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(VideoCompressJob.locateTools())
        let source = dir.appendingPathComponent("clip.mov")
        _ = try await ProcessRunner.run(tools.ffmpeg, [
            "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=2400x1350:rate=60:duration=2",
            "-pix_fmt", "yuv420p", source.path,
        ], timeout: 120)
        let before = try Data(contentsOf: source)

        let one = try await VideoCompressJob(input: source, settings: .init()).run { _ in }
        #expect(one.output.lastPathComponent == "clip (slack).mp4")
        #expect(one.compressedBytes > 0 && one.compressedBytes < one.originalBytes)

        let two = try await VideoCompressJob(input: source, settings: .init()).run { _ in }
        #expect(two.output.lastPathComponent == "clip (slack) 2.mp4")
        #expect(FileManager.default.fileExists(atPath: one.output.path))

        let probe = try await VideoCompressJob.probe(ffprobe: tools.ffprobe, input: one.output)
        #expect(probe.width == 1920 && probe.height == 1080)
        #expect((probe.fps ?? 0) <= 30.5)

        #expect(try Data(contentsOf: source) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["clip (slack) 2.mp4", "clip (slack).mp4", "clip.mov"])
    }

    @Test(.enabled(if: VideoCompressTests.ffmpegAvailable))
    func cancellingLeavesNoOutputBehind() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCompressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try #require(VideoCompressJob.locateTools())
        let source = dir.appendingPathComponent("long.mov")
        _ = try await ProcessRunner.run(tools.ffmpeg, [
            "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=3000x2000:rate=30:duration=60",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", source.path,
        ], timeout: 300)

        let job = VideoCompressJob(input: source, settings: .init(quality: .sharper))
        let task = Task { try await job.run { _ in } }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        job.cancel()
        await #expect(throws: VideoCompressError.cancelled) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["long.mov"])
    }

    @Test func rejectsANonVideoExtensionBeforeRunningAnything() async {
        let job = VideoCompressJob(input: URL(fileURLWithPath: "/tmp/x.png"), settings: .init())
        await #expect(throws: VideoCompressError.unsupported("png")) { try await job.run { _ in } }
    }
}
