import Foundation
import Testing
@testable import JuancodeCore

/// juancode-roi0: a child that asks the terminal a question — DSR (`ESC[6n`),
/// device attributes, XTWINOPS size — blocks until it gets an answer. With a live
/// view on the session that view answers; with nothing attached (headless
/// `juancode-serve`, a pane that was never revealed, any unattended session) the
/// headless model has to answer from its own VT state or the child hangs forever.
///
/// The contract these tests pin down: the model answers iff a responder is installed
/// AND no live view holds a claim, and a claim taken or released around a feed leaves
/// every query answered by exactly one party — never two.
@Suite struct TerminalModelDeviceQueryTests {
    private func esc(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Collects what the model writes back, standing in for the pty.
    final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [[UInt8]] = []
        func record(_ b: [UInt8]) { lock.withLock { chunks.append(b) } }
        var count: Int { lock.withLock { chunks.count } }
        var texts: [String] { lock.withLock { chunks.map { String(decoding: $0, as: UTF8.self) } } }
        var joined: String { texts.joined() }
    }

    /// A model wired to a reply sink, as `Session` wires one to its pty.
    private func headless(cols: Int = 80, rows: Int = 24) -> (SessionTerminalModel, Replies) {
        let m = SessionTerminalModel(cols: cols, rows: rows, scrollbackLines: 100)
        let replies = Replies()
        m.setDeviceQueryResponder { replies.record($0) }
        return (m, replies)
    }

    // MARK: - headless answers

    @Test func headlessModelAnswersCursorPositionReport() {
        let (m, replies) = headless()
        m.feed(esc("\u{1B}[3;7H"))       // park the cursor at row 3, col 7
        m.feed(esc("\u{1B}[6n"))         // DSR — the sequence that hangs a TUI
        #expect(replies.joined == "\u{1B}[3;7R")
        #expect(m.answeredDeviceQueries == 1)
    }

    @Test func headlessModelAnswersDeviceStatusAndAttributes() {
        let (m, replies) = headless()
        m.feed(esc("\u{1B}[5n"))         // DSR — "are you ok?"
        #expect(replies.joined == "\u{1B}[0n")

        let (m2, r2) = headless()
        m2.feed(esc("\u{1B}[c"))         // primary DA
        let primary = r2.joined
        #expect(primary.hasPrefix("\u{1B}[?"))
        #expect(primary.hasSuffix("c"))

        let (m3, r3) = headless()
        m3.feed(esc("\u{1B}[>c"))        // secondary DA
        #expect(r3.joined == "\u{1B}[>65;20;1c")
    }

    @Test func headlessModelAnswersWindowSizeQuery() {
        let (m, replies) = headless(cols: 100, rows: 30)
        m.feed(esc("\u{1B}[18t"))        // XTWINOPS: text area in characters
        #expect(replies.joined == "\u{1B}[8;30;100t")
        // And it answers at the CURRENT grid after a reflow, not the spawn one.
        m.resize(cols: 120, rows: 40)
        m.feed(esc("\u{1B}[18t"))
        #expect(replies.texts.last == "\u{1B}[8;40;120t")
    }

    @Test func repliesArriveInParseOrder() {
        let (m, replies) = headless(cols: 80, rows: 24)
        m.feed(esc("\u{1B}[1;1H\u{1B}[6n\u{1B}[5n\u{1B}[18t"))
        #expect(replies.texts == ["\u{1B}[1;1R", "\u{1B}[0n", "\u{1B}[8;24;80t"])
    }

    // MARK: - attached stays a no-op

    @Test func modelWithNoResponderDropsEveryQuery() {
        // The pre-roi0 behaviour, still what a bare model does: the activity
        // detector's private mirror and every test model must never write to a pty.
        let m = SessionTerminalModel(cols: 80, rows: 24, scrollbackLines: 100)
        #expect(!m.answersDeviceQueries)
        m.feed(esc("\u{1B}[6n\u{1B}[c\u{1B}[18t"))
        #expect(m.answeredDeviceQueries == 0)
    }

    @Test func attachedModelAnswersNothing() {
        let (m, replies) = headless()
        let claim = m.claimDeviceQueries()
        #expect(m.hasDeviceQueryClaim)
        #expect(!m.answersDeviceQueries)
        m.feed(esc("\u{1B}[6n\u{1B}[5n\u{1B}[18t"))
        #expect(replies.count == 0)
        #expect(m.answeredDeviceQueries == 0)

        // Detach and the duty comes straight back.
        claim()
        #expect(!m.hasDeviceQueryClaim)
        #expect(m.answersDeviceQueries)
        m.feed(esc("\u{1B}[6n"))
        #expect(replies.count == 1)
    }

    @Test func claimsNestAndTheHandleIsIdempotent() {
        let (m, replies) = headless()
        let first = m.claimDeviceQueries()
        let second = m.claimDeviceQueries()   // two panes on one session
        first()
        first()                               // a second release must not leak a slot
        m.feed(esc("\u{1B}[6n"))
        #expect(replies.count == 0)           // `second` still holds the duty
        second()
        m.feed(esc("\u{1B}[6n"))
        #expect(replies.count == 1)
    }

    // MARK: - the transition

    /// A query that straddles the attach: the bytes `ESC[6` arrive detached and the
    /// finishing `n` arrives with a view attached. The query is answered by whoever
    /// owns the duty when it COMPLETES, exactly once — not by both.
    @Test func queryStraddlingTheFlipIsAnsweredExactlyOnce() {
        let (m, replies) = headless()
        m.feed(esc("\u{1B}[1;1H\u{1B}[6"))    // query still incomplete
        let claim = m.claimDeviceQueries()
        m.feed(esc("n"))                      // completes while the view is attached
        #expect(replies.count == 0)           // that one is the view's to answer

        claim()
        m.feed(esc("\u{1B}[6"))
        m.feed(esc("n"))                      // completes detached
        #expect(replies.texts == ["\u{1B}[1;1R"])
        #expect(m.answeredDeviceQueries == 1)
    }

    /// A claim taken from another thread cannot land in the middle of a parse: `feed`
    /// holds the model lock for the whole chunk, which is what makes the decision in
    /// `send` atomic. So however the flips interleave with the feeds, the model's
    /// reply count never exceeds the number of queries — it never double-answers —
    /// and the count doesn't leak: once every claim is released it answers again.
    @Test func concurrentFlipsNeverDoubleAnswer() async {
        let (m, replies) = headless()
        let queries = 300
        let flipper = Task.detached {
            for _ in 0..<queries {
                let claim = m.claimDeviceQueries()
                claim()
            }
        }
        let feeder = Task.detached {
            for _ in 0..<queries { m.feed(Array("\u{1B}[6n".utf8)) }
        }
        _ = await (flipper.value, feeder.value)

        #expect(replies.count <= queries)
        #expect(replies.count == m.answeredDeviceQueries)
        // Every reply is a whole, well-formed CPR — no interleaved or truncated write.
        for t in replies.texts { #expect(t.hasPrefix("\u{1B}[") && t.hasSuffix("R")) }
        // No claim leaked, so the model is answering again.
        #expect(!m.hasDeviceQueryClaim)
        let before = m.answeredDeviceQueries
        m.feed(esc("\u{1B}[6n"))
        #expect(m.answeredDeviceQueries == before + 1)
    }
}

/// The same fix seen from the outside: a real child process on a real pty asks for
/// its cursor position and reads the answer back. Unattended — no view anywhere —
/// which is precisely the headless `juancode-serve` shape the child used to hang in.
@Suite struct SessionDeviceQueryTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = [UInt8]()
        func add(_ b: [UInt8]) { lock.withLock { data += b } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-dsr-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func env(script: String) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            scrollbackLimit: 256 * 1024,
            discoverCliSessionId: { _, _, _ in nil }
        )
    }

    private var tmp: String { FileManager.default.temporaryDirectory.path }

    /// The child emits DSR and then BLOCKS on reading the reply — the hang this
    /// ticket is about. It only reaches its second print if the session answered.
    @Test func unattendedChildGetsItsCursorPositionAnswered() async throws {
        let script = makeScript("""
        stty -echo
        printf 'ASKING\\n'
        printf '\\033[6n'
        IFS= read -r -d R reply
        printf 'CPR%s\\n' "${reply#*[}"
        cat
        """)
        let parent = SessionMeta(id: "dsr-parent", provider: .claude, cwd: tmp, title: "t",
                                 status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
                                 cliSessionId: nil, skipPermissions: false,
                                 worktreePath: tmp, usage: nil)
        let s = try Session.editor(parent: parent, executable: script, args: [],
                                   cols: 80, rows: 24, env: env(script: script))
        defer { s.kill() }

        let sink = ByteSink()
        s.subscribeOutput { sink.add($0) }
        await PtySpawn.poll(PtySpawn.firstFrameBound) { sink.text.contains("ASKING") }
        await PtySpawn.poll(PtySpawn.firstFrameBound) { sink.text.contains("CPR") }
        // Row 2 because "ASKING\n" moved the cursor down one line; column 1.
        #expect(sink.text.contains("CPR2;1"))
        #expect(s.terminalModel.answeredDeviceQueries == 1)
    }

    /// With a live view attached the session stays out of it — the view answers, and
    /// the model writing a second reply would land in the pty as garbage keystrokes.
    @Test func attachedSessionLeavesTheAnswerToTheView() async throws {
        // DSR first, so once ASKING is on screen the query is certainly parsed.
        let script = makeScript("printf '\\033[6n'\nprintf 'ASKING\\n'\ncat\n")
        let parent = SessionMeta(id: "dsr-parent-2", provider: .claude, cwd: tmp, title: "t",
                                 status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
                                 cliSessionId: nil, skipPermissions: false,
                                 worktreePath: tmp, usage: nil)
        let s = try Session.editor(parent: parent, executable: script, args: [],
                                   cols: 80, rows: 24, env: env(script: script))
        defer { s.kill() }
        let claim = s.attachLiveView()
        defer { claim() }

        let sink = ByteSink()
        s.subscribeOutput { sink.add($0) }
        await PtySpawn.poll(PtySpawn.firstFrameBound) { sink.text.contains("ASKING") }
        // The query is parsed (the model saw it) but nothing was written back.
        #expect(s.terminalModel.hasDeviceQueryClaim)
        #expect(s.terminalModel.answeredDeviceQueries == 0)
    }
}
