import Foundation
import Testing
@testable import JuancodeCore

/// The one bound every wait on a real pty child in this suite uses, and why it is
/// this large.
///
/// A spawn here is not fast, and the cost is not ours. Measured on the machine this
/// suite runs on (14 cores, an EndpointSecurity system extension installed):
///
///   fork + _exit, no exec at all      n=500  mean 0.454ms  p99 1.71ms  max 2.34ms
///   fork -> the child's own first userspace instruction, self-timed by the child
///   writing CLOCK_MONOTONIC to a pipe as its first act:            257ms, every time
///
/// So a quarter of a second of every spawn is spent inside `execve`, before the
/// child runs one instruction. It does not queue (at concurrency 32 the per-exec
/// latency is still 269ms and throughput scales linearly), so it is a flat latency
/// on the exec path, which is where an exec-authorization hook blocks. It is also
/// not something this code can avoid: a pty child is an exec.
///
/// Under this suite's own CPU load that latency stretches badly. Exec latency
/// sampled during a JuancodeCoreTests run: six batches of 25 with means of 772,
/// 879, 903, 882, 823 and 1130ms, and one single exec at 7521ms. End to end, the
/// spawn-to-first-frame distribution over a full run, instrumented in `PtyProcess`:
///
///   run 1  n=40  p50 2063ms  p90 6162ms  max 6560ms
///   run 2  n=37  p50 3041ms  p90 6368ms  max 7279ms
///   run 3  n=34  p50 2866ms  p90 5192ms  max 6707ms
///
/// The suites used to bound these waits at 3s and 5s, so the median first frame
/// landed on the bound and p90 was double it. That is one distribution whose tail
/// crossed whichever bound was shortest, which is why a different test failed each
/// run and why it was always exactly one session.
/// Alongside a concurrent `cargo test` at load average 70 the same wait has been
/// measured past 60s, and past 120s twice.
///
/// Hence 180s. It is a "the spawn is broken" bound, not a schedule: every caller
/// re-asserts its condition and the poll returns the instant it holds, so
/// overshooting only ever costs time on a test that was going to fail anyway.
enum PtySpawn {
    static let firstFrameBound: TimeInterval = 180

    static func poll(_ timeout: TimeInterval = firstFrameBound,
                     _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Wait for `cond` and, if it never came true, say whether the child is even
    /// alive. "expected READY, got empty" does not distinguish a child still parked
    /// in `execve` from one that died on spawn, and whoever reads the next failure
    /// needs that in the message.
    static func expectEventually(_ s: Session, _ what: String,
                                 _ cond: @escaping () -> Bool,
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
        await poll(firstFrameBound, cond)
        let why = "\(what) never arrived: running=\(s.isRunning) status=\(s.meta.status) "
            + "exit=\(String(describing: s.meta.exitCode))"
        #expect(cond(), Comment(rawValue: why), sourceLocation: sourceLocation)
    }
}
