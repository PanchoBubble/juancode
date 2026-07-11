import Testing
import XCTest
@testable import JuancodeServer

/// A thread-safe recorder for the emitted frames / resyncs.
private final class Sink: @unchecked Sendable {
    let lock = NSLock()
    var outputs: [(String, [UInt8])] = []
    var resyncs: [String] = []
    var backedUp = false
    func record(_ id: String, _ bytes: [UInt8]) { lock.lock(); outputs.append((id, bytes)); lock.unlock() }
    func recordResync(_ id: String) { lock.lock(); resyncs.append(id); lock.unlock() }
    func isBackedUp() -> Bool { lock.lock(); defer { lock.unlock() }; return backedUp }
}

private func make(maxBytes: Int = 1024) -> (ServerOutputCoalescer, Sink) {
    let sink = Sink()
    let c = ServerOutputCoalescer(
        maxBytes: maxBytes,
        autoFlush: false,
        isBackedUp: { [sink] in sink.isBackedUp() },
        emitOutput: { [sink] id, bytes in sink.record(id, bytes) })
    c.onResync = { [sink] id in sink.recordResync(id) }
    return (c, sink)
}

/// Coalescing + bounded-buffer behaviour for the server→client output path
/// (juancode-5qw.7). Uses `autoFlush: false` so `flushTick()` is driven manually —
/// no timers, so the assertions are deterministic.
final class ServerOutputCoalescerTests: XCTestCase {
    func testCoalescesMultipleChunksIntoOneFrame() {
        let (c, sink) = make()
        c.append("s-1", Array("foo".utf8))
        c.append("s-1", Array("bar".utf8))
        c.append("s-1", Array("baz".utf8))
        XCTAssertTrue(sink.outputs.isEmpty, "nothing flushes before a tick")
        c.flushTick()
        XCTAssertEqual(sink.outputs.count, 1, "three chunks coalesce into one frame")
        XCTAssertEqual(sink.outputs.first?.0, "s-1")
        XCTAssertEqual(sink.outputs.first.map { String(decoding: $0.1, as: UTF8.self) }, "foobarbaz")
    }

    func testSeparateSessionsGetSeparateFrames() {
        let (c, sink) = make()
        c.append("s-1", Array("a".utf8))
        c.append("s-2", Array("b".utf8))
        c.flushTick()
        XCTAssertEqual(sink.outputs.count, 2)
        XCTAssertEqual(Set(sink.outputs.map(\.0)), ["s-1", "s-2"])
    }

    func testStalledClientBufferStaysBounded() {
        let (c, sink) = make(maxBytes: 1024)
        sink.backedUp = true // writer stalled: the gate reports backpressure

        // Push far more than the cap; while backed up the tick emits nothing, and
        // the buffer must never exceed the cap.
        let chunk = Array(repeating: UInt8(0x41), count: 256)
        for _ in 0..<100 {
            c.append("s-1", chunk)
            c.flushTick()
            XCTAssertLessThanOrEqual(c.bufferedBytes, 1024, "buffer must stay bounded under a stall")
        }
        XCTAssertTrue(sink.outputs.isEmpty, "no output frames flush while backed up")
    }

    func testOverflowResyncsOnceClientRecovers() {
        let (c, sink) = make(maxBytes: 1024)
        sink.backedUp = true

        // Overflow the buffer while stalled — bytes are dropped and the session is
        // flagged for resync.
        let chunk = Array(repeating: UInt8(0x41), count: 256)
        for _ in 0..<20 { c.append("s-1", chunk) }
        c.flushTick()
        XCTAssertTrue(sink.outputs.isEmpty)
        XCTAssertTrue(sink.resyncs.isEmpty, "no resync emitted while still backed up")

        // Client catches up: the next tick repaints the session instead of
        // replaying a stream with a gap.
        sink.backedUp = false
        c.flushTick()
        XCTAssertEqual(sink.resyncs, ["s-1"], "overflow triggers a scrollback resync")
        XCTAssertTrue(sink.outputs.isEmpty, "dropped bytes are not replayed incrementally")
    }

    func testFlushSessionEmitsImmediately() {
        let (c, sink) = make()
        c.append("s-1", Array("bye".utf8))
        c.flushSession("s-1") // e.g. just before an exit frame
        XCTAssertEqual(sink.outputs.count, 1)
        XCTAssertEqual(sink.outputs.first.map { String(decoding: $0.1, as: UTF8.self) }, "bye")
        // Nothing left to flush on the next tick.
        c.flushTick()
        XCTAssertEqual(sink.outputs.count, 1)
    }

    func testForgetDropsBuffer() {
        let (c, sink) = make()
        c.append("s-1", Array("data".utf8))
        c.forget("s-1")
        XCTAssertEqual(c.bufferedBytes, 0)
        c.flushTick()
        XCTAssertTrue(sink.outputs.isEmpty)
    }

    func testStopHaltsFlushing() {
        let (c, sink) = make()
        c.append("s-1", Array("x".utf8))
        c.stop()
        c.append("s-1", Array("y".utf8)) // ignored after stop
        c.flushTick()
        XCTAssertTrue(sink.outputs.isEmpty)
        XCTAssertEqual(c.bufferedBytes, 0)
    }
}

/// A flush boundary can land mid-multibyte-glyph; the wire frame is a String, so
/// the coalescer must carry the incomplete trailing UTF-8 sequence into the next
/// flush instead of letting both halves decode to U+FFFD on the client.
@Suite struct ServerOutputCoalescerUtf8Tests {
    /// Decode one emitted frame the way the connection does for the wire.
    private func decoded(_ sink: Sink, _ i: Int) -> String {
        String(decoding: sink.outputs[i].1, as: UTF8.self)
    }

    @Test func emojiSplitAcrossTwoFlushesDecodesIntact() {
        let (c, sink) = make()
        let emoji = Array("🎉".utf8) // 4 bytes
        c.append("s-1", Array("a".utf8) + emoji[0..<2])
        c.flushTick()
        c.append("s-1", Array(emoji[2...]) + Array("b".utf8))
        c.flushTick()
        #expect(sink.outputs.count == 2)
        #expect(decoded(sink, 0) == "a", "incomplete emoji bytes are held back, not emitted as U+FFFD")
        #expect(decoded(sink, 1) == "🎉b", "held tail is prepended so the glyph decodes intact")
    }

    @Test func boxDrawingSplitAcrossFlushesDecodesIntact() {
        let (c, sink) = make()
        let glyph = Array("─".utf8) // 3 bytes: E2 94 80
        c.append("s-1", Array("x".utf8) + glyph[0..<2])
        c.flushTick()
        c.append("s-1", Array(glyph[2...]))
        c.flushTick()
        #expect(sink.outputs.count == 2)
        #expect(decoded(sink, 0) == "x")
        #expect(decoded(sink, 1) == "─")
    }

    @Test func tailOnlyFlushEmitsNothingAndCompletesLater() {
        let (c, sink) = make()
        let emoji = Array("😀".utf8)
        c.append("s-1", Array(emoji[0..<3])) // nothing but an incomplete sequence
        c.flushTick()
        #expect(sink.outputs.isEmpty, "a flush that is entirely an incomplete tail emits no frame")
        c.append("s-1", Array(emoji[3...]))
        c.flushTick()
        #expect(sink.outputs.count == 1)
        #expect(decoded(sink, 0) == "😀")
    }

    @Test func invalidBytesStillEmitWithoutStalling() {
        let (c, sink) = make()
        // An invalid lead and a stray continuation: not a truncated sequence, so
        // they must flush through (as replacement chars on decode), never be held.
        c.append("s-1", [0x41, 0xFF, 0x80, 0x42])
        c.flushTick()
        #expect(sink.outputs.count == 1)
        #expect(sink.outputs[0].1 == [0x41, 0xFF, 0x80, 0x42])
        // Nothing carried: the next flush is independent.
        c.append("s-1", Array("ok".utf8))
        c.flushTick()
        #expect(sink.outputs.count == 2)
        #expect(decoded(sink, 1) == "ok")
    }

    @Test func finalFlushEmitsHeldTail() {
        let (c, sink) = make()
        let emoji = Array("🎉".utf8)
        c.append("s-1", Array("end".utf8) + emoji[0..<2])
        c.flushTick() // emits "end", holds the 2 tail bytes
        #expect(decoded(sink, 0) == "end")
        c.flushSession("s-1") // pre-exit flush: the stream truly ends here
        #expect(sink.outputs.count == 2)
        #expect(sink.outputs[1].1 == Array(emoji[0..<2]), "held bytes are emitted, not silently dropped")
        // And the carry is gone — a later tick emits nothing more.
        c.flushTick()
        #expect(sink.outputs.count == 2)
    }

    @Test func flushSessionJoinsHeldTailWithNewBytes() {
        let (c, sink) = make()
        let emoji = Array("🎉".utf8)
        c.append("s-1", Array(emoji[0..<2]))
        c.flushTick() // holds both bytes, emits nothing
        #expect(sink.outputs.isEmpty)
        c.append("s-1", Array(emoji[2...]))
        c.flushSession("s-1")
        #expect(sink.outputs.count == 1)
        #expect(decoded(sink, 0) == "🎉")
    }

    @Test func forgetDropsHeldTail() {
        let (c, sink) = make()
        c.append("s-1", Array(Array("😀".utf8)[0..<3]))
        c.flushTick() // holds the incomplete bytes
        c.forget("s-1")
        c.append("s-1", Array("z".utf8))
        c.flushTick()
        #expect(sink.outputs.count == 1)
        #expect(decoded(sink, 0) == "z", "a forgotten session's tail does not leak into a new subscription")
    }
}
