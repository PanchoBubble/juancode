import SwiftUI
import QuartzCore
import Darwin

/// Lightweight performance instrumentation for diagnosing UI lag (juancode perf).
///
/// Everything is gated on `visible`: when the HUD is hidden there are no timers and
/// the per-feed/per-body hooks short-circuit on a single atomic-flag check, so the
/// monitor costs nothing in normal use. Toggle with ⌘⇧P.
///
/// What it measures:
/// - **CPU / memory** of this process (mach task/thread info), sampled each second.
/// - **Worst frame** — a high-frequency main-queue timer measures its own scheduling
///   drift; when the main thread is blocked (re-render storms, heavy feeds) the
///   timer fires late, so the largest gap in the last second is a direct jank proxy,
///   along with a count of frames over 32 ms (dropped at 60 Hz → ~2+ frames).
/// - **Terminal throughput** — KB/s and feed-calls/s pushed into the focused view.
/// - **View bodies/s** — how often instrumented SwiftUI views re-evaluate; a spike
///   here on an unrelated state change is the signature of an over-broad observable.
@MainActor
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    @Published var visible = false {
        didSet {
            guard visible != oldValue else { return }
            Self.enabled = visible
            visible ? start() : stop()
        }
    }

    @Published private(set) var cpuPercent = 0.0
    @Published private(set) var memoryMB = 0.0
    @Published private(set) var worstFrameMs = 0.0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var feedKBPerSec = 0.0
    @Published private(set) var feedCallsPerSec = 0
    @Published private(set) var bodyEvalsPerSec = 0

    /// Fast gate read on hot paths (feed/body hooks) so recording is a single bool
    /// check when the HUD is off. Main-actor-isolated like the rest of the type —
    /// every access (the `recordFeed`/`recordBody` hooks and the `visible` toggle)
    /// is already on the main actor, so this needs no unsafe opt-out and carries no
    /// data race (juancode-n9e; was `nonisolated(unsafe)`).
    private static var enabled = false

    // Counters accumulated between 1 s samples.
    private var feedBytes = 0
    private var feedCalls = 0
    private var bodyEvals = 0

    // Frame-drift tracking within the current sample window.
    private var lastFrame: CFTimeInterval = 0
    private var windowWorst = 0.0
    private var windowDropped = 0

    private var frameTimer: Timer?
    private var sampleTimer: Timer?

    private init() {}

    /// Record bytes fed into a terminal view (called on the main thread).
    static func recordFeed(_ byteCount: Int) {
        guard enabled else { return }
        let m = shared
        m.feedBytes += byteCount
        m.feedCalls += 1
    }

    /// Record one SwiftUI body evaluation of an instrumented view.
    static func recordBody() {
        guard enabled else { return }
        shared.bodyEvals += 1
    }

    private func start() {
        lastFrame = 0
        windowWorst = 0
        windowDropped = 0
        // ~120 Hz probe so we can see sub-frame stalls; runs in .common mode so it
        // keeps firing during scroll/resize tracking loops (where lag shows up).
        let ft = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFrame() }
        }
        RunLoop.main.add(ft, forMode: .common)
        frameTimer = ft

        let st = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sampleTimer = st
    }

    private func stop() {
        frameTimer?.invalidate(); frameTimer = nil
        sampleTimer?.invalidate(); sampleTimer = nil
    }

    private func tickFrame() {
        let now = CACurrentMediaTime()
        defer { lastFrame = now }
        guard lastFrame != 0 else { return }
        let deltaMs = (now - lastFrame) * 1000
        windowWorst = max(windowWorst, deltaMs)
        if deltaMs > 32 { windowDropped += 1 }
    }

    private func sample() {
        cpuPercent = Self.cpuUsage()
        memoryMB = Self.residentMB()
        worstFrameMs = windowWorst
        droppedFrames = windowDropped
        feedKBPerSec = Double(feedBytes) / 1024
        feedCallsPerSec = feedCalls
        bodyEvalsPerSec = bodyEvals
        windowWorst = 0; windowDropped = 0
        feedBytes = 0; feedCalls = 0; bodyEvals = 0
    }

    // MARK: - mach sampling

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func cpuUsage() -> Double {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        // THREAD_BASIC_INFO_COUNT is a C macro that doesn't import into Swift.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var tcount = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &tcount)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }
}

extension View {
    /// Count this view's body re-evaluations into the perf HUD. No-op when the HUD
    /// is off. Place on views you suspect re-render too often.
    func perfTrackBody() -> some View {
        PerfMonitor.recordBody()
        return self
    }
}
