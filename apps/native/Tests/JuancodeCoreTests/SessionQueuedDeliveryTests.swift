import Foundation
import Testing
@testable import JuancodeCore

/// Delivery tests for the outbound message queue (`Session.flushQueue` →
/// `deliverQueued`) against a fake CLI in a real pty.
///
/// The hard case here is the one the seed path never faces: the queue runs
/// mid-session, so the message text can already be on screen — the user typed it
/// earlier, the agent quoted it back, a previous failed delivery left it in the
/// history. Every fake CLI below therefore prints the message as transcript
/// *before* delivery starts, so a land check that searched the whole screen would
/// report landed off that stale text and press Enter into a box the paste never
/// reached.
///
/// The fake CLI leaves the tty in its default mode, so the terminal driver echoes
/// a bracketed paste back as literal text with no collapsed-paste chip — how
/// `claude` renders a paste too tall for the input box. The script records one line
/// per paste, and one line per Enter that arrived after a completed paste.
@Suite struct SessionQueuedDeliveryTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// Rows of the bottom screen region the queued land check reads (mirrors
    /// `Session.Seed.inputRows`, which is private). The message below renders
    /// taller than this, which is the whole point.
    private let inputRows = 16

    /// The tty's canonical-mode input queue, `TTYHOG` in xnu's `bsd/sys/tty.h`. Once
    /// `t_rawq + t_canq` reaches it, `ttyinput` DISCARDS the rest of what is being
    /// written (with `IMAXBEL` it rings the bell and drops the character) instead of
    /// pushing back on the writer, and a write to the pty master reports a clean
    /// success for bytes the line discipline then threw away.
    ///
    /// That is what juancode-xfbr was: at 1228 bytes this suite's payload was over the
    /// cap, so under a loaded runner — where the fake CLI, a bash `read` loop taking
    /// one byte at a time, could not drain fast enough — the driver kept the first
    /// ~1007 bytes and dropped the tail line and the closing `ESC[201~` with them. The
    /// paste's head reached the child (so it logged one paste) while its tail never
    /// existed, and no amount of waiting or retrying could make a land check see a
    /// signature that had been discarded a layer below us. Measured on macos-15 in CI,
    /// where the echoed screen stopped mid-"Note 16" in 6 of 10 full runs.
    ///
    /// Real agent CLIs never hit this: they put the tty in raw mode, where `ptcwrite`
    /// blocks at `TTYHOG - 2` unconditionally and our non-blocking write gets EAGAIN
    /// and retries. It is the canonical mode this suite deliberately leaves the fake
    /// CLI in — the thing that makes the paste echo back as literal text — that makes
    /// an over-size paste lossy. So the payload has to stay under the cap.
    private let ttyInputQueueBytes = 1024

    /// A message whose literal rendering is taller than the input-box footer: 18
    /// lines, each short enough not to wrap at 80 columns, so its first line (the
    /// head signature) sits well above the bottom `inputRows` rows and only its
    /// last line (the tail signature) is still down there. Deliberately free of the
    /// activity detector's working/prompt tokens so the echoed text can't classify
    /// the fake session busy or waiting by itself.
    ///
    /// Tall means ROWS, not bytes, and the two pull in opposite directions here: the
    /// rendering has to be taller than `inputRows` while the payload stays under
    /// `ttyInputQueueBytes`. Hence short lines. `payloadFitsTheTtyInputQueue` holds
    /// the line, so lengthening this by hand fails loudly instead of flaking in CI.
    private var tallMessage: String {
        var lines = ["Follow up on the batch import"]
        for i in 1...16 {
            lines.append("Note \(i): list the changed files.")
        }
        lines.append("Wrap up with a short summary.")
        return lines.joined(separator: "\n")
    }

    /// `onPaste` runs when a paste arrives and `onEnter` when a real Enter terminates
    /// a completed paste; `extraSetup` runs once at startup, before the transcript.
    /// `stty -echo` there is how a paste that never reaches the input box is simulated.
    private func makeFakeCli(
        log: String, transcript: String, onPaste: String = "", onEnter: String = "", extraSetup: String = ""
    ) -> String {
        let body = """
        LOG='\(log)'
        \(extraSetup.isEmpty ? ":" : extraSetup)
        while IFS= read -r l; do printf '%s\\r\\n' "$l"; done < '\(transcript)'
        printf 'fake-claude ready\\r\\n'
        while IFS= read -r line; do
          case "$line" in
            *$'\\033'"[200~"*) printf 'paste\\n' >>"$LOG"; \(onPaste.isEmpty ? ":" : onPaste) ;;
          esac
          case "$line" in
            *$'\\033'"[201~") printf 'enter\\n' >>"$LOG"; \(onEnter.isEmpty ? ":" : onEnter) ;;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Write `text` where the fake CLI can replay it as its startup transcript. The
    /// trailing newline matters: the replay loop is a `read`, which drops a final
    /// unterminated line — and that line is the tail signature the test turns on.
    private func makeTranscript(_ text: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-transcript-\(UUID().uuidString).txt")
        try! (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func makeLogPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-queued-\(UUID().uuidString).log").path
    }

    private func count(_ event: String, in log: String) -> Int {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { $0 == event }.count
    }

    /// Wait for `cond`, polling rather than sleeping a fixed window, so a loaded
    /// machine costs latency and not a failure. Returns whether it came true.
    ///
    /// The default is derived from what the delivery machine is allowed to spend, not
    /// from a guess about machine speed: one `deliverQueued` pass allows 4s to confirm
    /// the paste landed plus 3 x 4s of Enter retries, and a pass that gives up leaves
    /// the message queued for the next idle edge to retry. 30s covered barely two
    /// passes and reported "never delivered" for a delivery still legitimately in
    /// flight; 90s covers five.
    @discardableResult
    private func poll(_ timeout: TimeInterval = 90.0, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    private func env(script: String, queue: MessageQueue, log: SessionActivityLogging) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil },
            log: log
        )
    }

    /// A real activity log in a throwaway directory. The delivery machine records
    /// `queuedPaste` / `queuedEnter` / `queuedResult` there, which is the only
    /// timestamped account of what a delivery did — and this suite's failure mode
    /// (juancode-xfbr) is only reproducible inside a full run, where re-running the
    /// test by hand tells you nothing. Cheap enough to leave on always.
    private func makeActivityLog() -> SessionActivityLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-queued-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionActivityLog(directory: dir.path)
    }

    /// Everything the land check reads, sampled at failure time. A red run should
    /// say by itself whether the child never rendered the paste or the check
    /// refused to see what it rendered, instead of leaving the next reader to guess.
    private func deliveryDiagnostic(
        _ s: Session, activity: SessionActivityLog, log: String, head: String, tail: String
    ) -> String {
        let footer = InitialPromptDelivery.normalize(s.terminalModel.bottomText(inputRows))
        let screen = InitialPromptDelivery.normalize(s.terminalModel.visibleText())
        let trail = (try? String(contentsOfFile: activity.logPath, encoding: .utf8)) ?? "<none>"
        return """

        grid=\(s.terminalModel.cols)x\(s.terminalModel.rows) activity=\(s.activity) \
        running=\(s.isRunning)
        footer holds head=\(InitialPromptDelivery.region(footer, contains: head)) \
        tail=\(InitialPromptDelivery.region(footer, contains: tail))
        screen holds head=\(InitialPromptDelivery.region(screen, contains: head)) \
        tail=\(InitialPromptDelivery.region(screen, contains: tail))
        child log: paste=\(count("paste", in: log)) enter=\(count("enter", in: log))
        footer: \(footer)
        activity trail:
        \(trail)
        """
    }

    /// Spawn a live session whose screen already shows `transcript`, and wait until
    /// it is settled and idle — the state the queue flush fires in.
    private func liveIdleSession(
        log: String, transcript: String, onPaste: String = "", onEnter: String = "",
        extraSetup: String = "", queue: MessageQueue,
        activityLog: SessionActivityLogging = NoopSessionActivityLog()
    ) async throws -> Session {
        let script = makeFakeCli(
            log: log, transcript: makeTranscript(transcript),
            onPaste: onPaste, onEnter: onEnter, extraSetup: extraSetup)
        let s = try Session.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24, env: env(script: script, queue: queue, log: activityLog))
        let ready = await poll {
            s.activity == .idle
                && s.terminalModel.visibleText().contains("fake-claude ready")
        }
        #expect(ready, "the fake CLI never reached a settled idle screen")
        return s
    }

    @Test func tallMessageOverAnEchoingTranscriptLandsOnceAndIsActuallySubmitted() async throws {
        let log = makeLogPath()
        let queue = MessageQueue()
        let activity = makeActivityLog()
        // The message is already in the transcript before delivery starts, and its
        // *tail* is sitting in the very footer rows the land check reads.
        let s = try await liveIdleSession(
            log: log, transcript: tallMessage,
            onEnter: #"printf 'crunching... esc to interrupt\r\n'"#, queue: queue,
            activityLog: activity)
        defer { s.kill() }

        let head = InitialPromptDelivery.signature(for: tallMessage)
        let tail = Session.tailSignature(for: tallMessage)
        #expect(InitialPromptDelivery.region(s.terminalModel.bottomText(inputRows), contains: tail))
        #expect(!InitialPromptDelivery.region(s.terminalModel.bottomText(inputRows), contains: head))

        queue.add(s.id, text: tallMessage)
        s.kickQueue()

        // The queue drops a message only once delivery is confirmed, so an empty
        // queue is the observable "it went through".
        let delivered = await poll { queue.list(s.id).isEmpty }
        let diagnose = { self.deliveryDiagnostic(s, activity: activity, log: log, head: head, tail: tail) }
        #expect(delivered, "the message was never confirmed delivered\(diagnose())")

        // Read the log only once the child has *recorded* the Enter. Delivery can be
        // confirmed off the screen while the CR is still sitting in the tty buffer, so
        // reading immediately made the log look like no Enter was sent on a loaded
        // machine. The child reads its input in order, so waiting on the Enter line
        // also makes the paste count trustworthy.
        await poll { self.count("enter", in: log) > 0 }
        // Pasted exactly once: the queue's retry stacking duplicate copies is the
        // other half of this bug class.
        #expect(count("paste", in: log) == 1)
        // And the Enter really went out — a delivered message with no Enter is the
        // false success this test exists for.
        #expect(count("enter", in: log) == 1, "no Enter reached the child\(diagnose())")
        // Rendered literally, with no collapsed-paste chip to fall back on.
        #expect(!InitialPromptDelivery.regionShowsCollapsedPaste(s.terminalModel.visibleText()))
    }

    @Test func pasteChurnGoingBusyDoesNotSkipTheEnter() async throws {
        // A CLI that paints its working footer while digesting the paste flips the
        // detector busy mid-delivery. Busy churn from our own paste is not a
        // submitted message, so the Enter must still be sent.
        let log = makeLogPath()
        let queue = MessageQueue()
        let s = try await liveIdleSession(
            log: log, transcript: tallMessage,
            onPaste: #"printf 'crunching... esc to interrupt\r\n'"#, queue: queue)
        defer { s.kill() }

        queue.add(s.id, text: tallMessage)
        s.kickQueue()

        let delivered = await poll { queue.list(s.id).isEmpty }
        #expect(delivered, "the message was never confirmed delivered")
        await poll { self.count("enter", in: log) > 0 }
        #expect(count("paste", in: log) == 1)
        #expect(count("enter", in: log) >= 1)
    }

    @Test func aPasteThatNeverReachesTheBoxIsNotLandedOffStaleTranscript() async throws {
        // Echo off: the paste reaches the child but nothing of it appears on screen,
        // while the message text is already in the transcript. A whole-screen land
        // check would call that landed and fire an Enter into a box holding nothing.
        let log = makeLogPath()
        let queue = MessageQueue()
        let s = try await liveIdleSession(
            log: log, transcript: tallMessage, extraSetup: "stty -echo", queue: queue)
        defer { s.kill() }

        queue.add(s.id, text: tallMessage)
        s.kickQueue()

        #expect(await poll { count("paste", in: log) >= 1 }, "the paste never reached the fake CLI")
        // Generous window: an Enter sent off stale text would arrive right after the
        // land budget expires, so waiting well past it is the whole assertion.
        _ = await poll(15.0) { count("enter", in: log) > 0 }
        #expect(count("enter", in: log) == 0)
        // Undelivered means still queued, to be retried on the next idle edge.
        #expect(!queue.list(s.id).isEmpty)
    }

    @Test func aResizeBetweenThePasteAndItsEchoStillSubmits() async throws {
        // Echo off, and the child paints the payload's tail itself a beat after the
        // paste arrives, so the resize below lands between our write and the land
        // check seeing it. The transcript fills the screen so the footer rows are
        // live, and does not hold the message, which is what lets the check trust the
        // payload across the changed grid.
        let log = makeLogPath()
        let queue = MessageQueue()
        let activity = makeActivityLog()
        let s = try await liveIdleSession(
            log: log, transcript: (1...30).map { "earlier turn line \($0)" }.joined(separator: "\n"),
            onPaste: #"sleep 1; printf 'Wrap up with a short summary.\r\n'"#,
            onEnter: #"printf 'crunching... esc to interrupt\r\n'"#,
            extraSetup: "stty -echo", queue: queue, activityLog: activity)
        defer { s.kill() }
        // The boot re-apply would otherwise put the grid back mid-test.
        #expect(await poll { s.bootGridSettled })

        queue.add(s.id, text: tallMessage)
        s.kickQueue()

        #expect(await poll { count("paste", in: log) >= 1 }, "the paste never reached the fake CLI")
        s.resizeLocal(cols: 100, rows: 30)

        let delivered = await poll { queue.list(s.id).isEmpty }
        let head = InitialPromptDelivery.signature(for: tallMessage)
        let tail = Session.tailSignature(for: tallMessage)
        #expect(delivered, """
            a grid change mid-delivery pinned the message to the old grid\
            \(deliveryDiagnostic(s, activity: activity, log: log, head: head, tail: tail))
            """)
        await poll { self.count("enter", in: log) > 0 }
        #expect(count("paste", in: log) == 1)
        #expect(count("enter", in: log) == 1)
    }

    @Test func theLandCheckAcrossAGridChangeTrustsOnlyAPayloadThatWasNotThereBefore() {
        let head = "follow up on the batch i"
        let tail = "wrap up with a short sum"
        let empty = Session.FooterSnapshot(text: "> ", cols: 80, rows: 24)
        let stale = Session.FooterSnapshot(text: "wrap up with a short summary. > ", cols: 80, rows: 24)
        let landedWider = Session.FooterSnapshot(text: "wrap up with a short summary. >", cols: 100, rows: 30)
        let landedSame = Session.FooterSnapshot(text: "wrap up with a short summary. >", cols: 80, rows: 24)

        #expect(Session.queuedLanded(now: landedSame, before: empty, head: head, tail: tail))
        #expect(Session.queuedLanded(now: landedWider, before: empty, head: head, tail: tail))
        // The old footer already held a copy, so after a reflow nothing tells the two apart.
        #expect(!Session.queuedLanded(now: landedWider, before: stale, head: head, tail: tail))
        // A re-framed window that does not show the payload is never a landing.
        let reframed = Session.FooterSnapshot(text: "something else", cols: 100, rows: 30)
        #expect(!Session.queuedLanded(now: reframed, before: empty, head: head, tail: tail))
        #expect(!Session.queuedLanded(now: stale, before: stale, head: head, tail: tail))
    }

    @Test func theRetryBacksOffAndNeverRunsOut() {
        #expect(Session.queueRetryDelayMs(attempt: 1) == 3_000)
        #expect(Session.queueRetryDelayMs(attempt: 2) == 6_000)
        #expect(Session.queueRetryDelayMs(attempt: 3) == 10_000)
        #expect(Session.queueRetryDelayMs(attempt: 6) == 10_000)
        #expect(Session.queueRetryDelayMs(attempt: 1_000) == 10_000)
    }

    @Test func payloadFitsTheTtyInputQueue() {
        // The guard juancode-xfbr cost four days of red main to learn. Everything this
        // suite asserts about a queued delivery is downstream of the whole paste
        // actually reaching the child, and in canonical mode the tty stops being a
        // pipe and starts being a 1KB bucket that throws away the overflow. Keep the
        // margin: the bracketed-paste markers ride along, and the queue may be asked
        // to deliver while the child still holds part of an earlier line.
        let bytes = tallMessage.utf8.count + PasteEngine.startMarker.count + PasteEngine.endMarker.count
        #expect(bytes < ttyInputQueueBytes, "a paste this size is lossy in canonical mode: \(bytes) bytes")
        // And it is still taller than the footer, which is the other half of the point
        // — a payload trimmed until it fits in the input box tests nothing.
        #expect(tallMessage.split(separator: "\n").count > inputRows)
    }

    @Test func tailSignatureIsTakenFromTheLastNonEmptyLine() {
        let text = "first line of the payload\nmiddle\nthe last line that the footer keeps\n\n  \n"
        #expect(Session.tailSignature(for: text) == "the last line that the f")
        // Single-line payloads collapse to the same signature as the head, which is
        // harmless: the land check ORs the two.
        #expect(Session.tailSignature(for: "just one line") == "just one line")
        #expect(Session.tailSignature(for: "   \n\n").isEmpty)
    }
}
