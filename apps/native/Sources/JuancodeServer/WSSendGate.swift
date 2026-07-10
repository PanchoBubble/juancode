import Foundation

/// Serialises server→client frames onto one `AsyncStream` and tracks how many are
/// queued-but-unwritten, so the output coalescer can tell when the socket writer
/// has fallen behind (juancode-5qw.7).
///
/// The writer task drains the stream one frame at a time, `await`ing each socket
/// write; a stalled remote client suspends that write, so `inFlight` climbs. Once
/// it crosses `highWater` the connection is "backed up" and the coalescer stops
/// pushing output frames — buffering (and, past its cap, dropping-then-resyncing)
/// them instead of growing this stream without bound.
///
/// Control frames (activity, exit, acks, …) are low-volume and are never gated, so
/// they always reach the client in order.
final class WSSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private let highWater: Int
    private let cont: AsyncStream<ServerMessage>.Continuation

    init(highWater: Int = 8, cont: AsyncStream<ServerMessage>.Continuation) {
        self.highWater = highWater
        self.cont = cont
    }

    /// Enqueue a frame for the writer (any thread).
    func send(_ msg: ServerMessage) {
        lock.lock(); inFlight += 1; lock.unlock()
        cont.yield(msg)
    }

    /// The writer finished one frame — called after every socket write.
    func didWrite() {
        lock.lock(); if inFlight > 0 { inFlight -= 1 }; lock.unlock()
    }

    /// True while more than `highWater` frames are queued unwritten.
    var backedUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > highWater
    }
}
