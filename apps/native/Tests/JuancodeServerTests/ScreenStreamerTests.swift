import XCTest
import JuancodeCore
@testable import JuancodeServer

/// The rendered-screen stream (juancode-a2h.3): a full snapshot on start, then
/// coalesced row-diffs from the model's damage stream. Uses `autoFlush: false` so
/// `flushTick()` is driven manually — no timers, deterministic assertions.
final class ScreenStreamerTests: XCTestCase {
    /// Thread-safe recorder for emitted frames + the backpressure flag.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [ServerMessage] = []
        private var _backedUp = false
        var frames: [ServerMessage] { lock.lock(); defer { lock.unlock() }; return _frames }
        var backedUp: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _backedUp }
            set { lock.lock(); _backedUp = newValue; lock.unlock() }
        }
        func send(_ m: ServerMessage) { lock.lock(); _frames.append(m); lock.unlock() }
    }

    /// A client-side reconstruction of the screen from `screen` frames — the same
    /// apply rule the sidecar's ScreenMirror implements: `reset` replaces the whole
    /// grid, otherwise patch the listed rows.
    private struct Mirror {
        var cols = 0, rows = 0
        var alt = false
        var lines: [Int: [ScreenSegmentWire]] = [:]

        mutating func apply(_ msg: ServerMessage) {
            guard case let .screen(_, reset, cols, rows, _, _, _, alt, lines) = msg else { return }
            if reset { self.lines.removeAll() }
            self.cols = cols; self.rows = rows; self.alt = alt
            for l in lines { self.lines[l.row] = l.segs }
        }

        func text(_ row: Int) -> String { (lines[row] ?? []).map(\.text).joined() }
    }

    private func make(cols: Int = 40, rows: Int = 6)
        -> (SessionTerminalModel, ScreenStreamer, Sink) {
        let model = SessionTerminalModel(cols: cols, rows: rows, scrollbackLines: 100)
        let sink = Sink()
        let streamer = ScreenStreamer(
            sessionId: "s-1", model: model, autoFlush: false,
            isBackedUp: { [sink] in sink.backedUp },
            send: { [sink] in sink.send($0) })
        return (model, streamer, sink)
    }

    private func screenFields(_ msg: ServerMessage?)
        -> (reset: Bool, cols: Int, rows: Int, lines: [ScreenRowWire])? {
        guard case let .screen(_, reset, cols, rows, _, _, _, _, lines) = msg else { return nil }
        return (reset, cols, rows, lines)
    }

    func testStartSendsFullSnapshot() {
        let (model, streamer, sink) = make()
        model.feed(Array("hello".utf8))
        streamer.start()
        XCTAssertEqual(sink.frames.count, 1)
        guard let f = screenFields(sink.frames.first) else { return XCTFail("expected .screen") }
        XCTAssertTrue(f.reset)
        XCTAssertEqual(f.cols, 40)
        XCTAssertEqual(f.rows, 6)
        XCTAssertEqual(f.lines.count, 6, "reset frame carries every visible row")
        XCTAssertEqual(f.lines[0].segs.map(\.text).joined(), "hello")
        streamer.stop()
    }

    func testDiffCarriesOnlyChangedRows() {
        let (model, streamer, sink) = make()
        model.feed(Array("hello".utf8))
        streamer.start()
        model.feed(Array("\r\nworld".utf8))
        streamer.flushTick()
        XCTAssertEqual(sink.frames.count, 2)
        guard let f = screenFields(sink.frames.last) else { return XCTFail("expected .screen") }
        XCTAssertFalse(f.reset)
        XCTAssertEqual(f.lines.map(\.row), [1], "row 0 didn't change; only the new row ships")
        XCTAssertEqual(f.lines[0].segs.map(\.text).joined(), "world")
        streamer.stop()
    }

    func testNoFrameWhenNothingChanged() {
        let (model, streamer, sink) = make()
        model.feed(Array("hi".utf8))
        streamer.start()
        streamer.flushTick()
        streamer.flushTick()
        XCTAssertEqual(sink.frames.count, 1, "no damage since start — ticks emit nothing")
        streamer.stop()
    }

    func testStalledTickEmitsNothingThenOneCoalescedDiff() {
        let (model, streamer, sink) = make()
        streamer.start()
        sink.backedUp = true
        // A busy burst while the writer is stalled: nothing may be emitted, and the
        // diff base must not advance.
        for i in 0..<10 {
            model.feed(Array("line \(i)\r\n".utf8))
            streamer.flushTick()
        }
        XCTAssertEqual(sink.frames.count, 1, "only the initial snapshot while backed up")
        // Once the writer drains, ONE diff frame covers the whole burst.
        sink.backedUp = false
        streamer.flushTick()
        XCTAssertEqual(sink.frames.count, 2)

        var mirror = Mirror()
        for f in sink.frames { mirror.apply(f) }
        let full = ScreenWire.fullLines(model.snapshot())
        for row in full {
            XCTAssertEqual(mirror.lines[row.row] ?? [], row.segs,
                           "row \(row.row) reconstructs to the live screen")
        }
        streamer.stop()
    }

    func testReconstructionMatchesFullSnapshotAcrossManyDiffs() {
        let (model, streamer, sink) = make()
        model.feed(Array("$ start\r\n".utf8))
        streamer.start()
        // Styled, overwriting, scrolling output across several ticks.
        let bursts = [
            "\u{1B}[31mred alert\u{1B}[0m\r\n",
            "plain text line\r\n",
            "\u{1B}[1;44mbold on blue\u{1B}[0m\r\n",
            "\u{1B}[2Aoverwrite up two\r\n",
            "tail 1\r\ntail 2\r\ntail 3\r\ntail 4\r\n", // pushes the screen to scroll
        ]
        for b in bursts {
            model.feed(Array(b.utf8))
            streamer.flushTick()
        }
        var mirror = Mirror()
        for f in sink.frames { mirror.apply(f) }
        let snap = model.snapshot()
        let full = ScreenWire.fullLines(snap)
        XCTAssertEqual(mirror.cols, snap.cols)
        XCTAssertEqual(mirror.rows, snap.rows)
        for row in full {
            XCTAssertEqual(mirror.lines[row.row] ?? [], row.segs,
                           "row \(row.row): diffs must reconstruct the same screen as a fresh snapshot")
        }
        streamer.stop()
    }

    func testGeometryChangeRepaintsWholesale() {
        let (model, streamer, sink) = make()
        model.feed(Array("before".utf8))
        streamer.start()
        model.resize(cols: 60, rows: 10)
        model.feed(Array("after".utf8))
        streamer.flushTick()
        guard let f = screenFields(sink.frames.last) else { return XCTFail("expected .screen") }
        XCTAssertTrue(f.reset, "a resize invalidates row indices — repaint wholesale")
        XCTAssertEqual(f.cols, 60)
        XCTAssertEqual(f.rows, 10)
        XCTAssertEqual(f.lines.count, 10)
        streamer.stop()
    }

    func testAltScreenFlipRepaintsWholesale() {
        let (model, streamer, sink) = make()
        model.feed(Array("normal buffer".utf8))
        streamer.start()
        model.feed(Array("\u{1B}[?1049htui screen".utf8))
        streamer.flushTick()
        guard case let .screen(_, reset, _, _, _, _, _, alt, _)? = sink.frames.last else {
            return XCTFail("expected .screen")
        }
        XCTAssertTrue(reset)
        XCTAssertTrue(alt)
        streamer.stop()
    }

    func testStopSilencesFurtherDamage() {
        let (model, streamer, sink) = make()
        streamer.start()
        streamer.stop()
        model.feed(Array("after stop".utf8))
        streamer.flushTick()
        XCTAssertEqual(sink.frames.count, 1, "only the initial snapshot")
    }
}
