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

    /// A message whose literal rendering is taller than the input-box footer: 20
    /// lines, each short enough not to wrap at 80 columns, so its first line (the
    /// head signature) sits well above the bottom `inputRows` rows and only its
    /// last line (the tail signature) is still down there. Deliberately free of the
    /// activity detector's working/prompt tokens so the echoed text can't classify
    /// the fake session busy or waiting by itself.
    private var tallMessage: String {
        var lines = ["Follow up on the batch import and report what moved"]
        for i in 1...18 {
            lines.append("Note \(i): list the changed files, then say what each one does.")
        }
        lines.append("Wrap up with a one paragraph summary of the batch import.")
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

    private func env(script: String, queue: MessageQueue) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            messageQueue: queue,
            discoverCliSessionId: { _, _, _ in nil }
        )
    }

    /// Spawn a live session whose screen already shows `transcript`, and wait until
    /// it is settled and idle — the state the queue flush fires in.
    private func liveIdleSession(
        log: String, transcript: String, onPaste: String = "", onEnter: String = "",
        extraSetup: String = "", queue: MessageQueue
    ) async throws -> Session {
        let script = makeFakeCli(
            log: log, transcript: makeTranscript(transcript),
            onPaste: onPaste, onEnter: onEnter, extraSetup: extraSetup)
        let s = try Session.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24, env: env(script: script, queue: queue))
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
        // The message is already in the transcript before delivery starts, and its
        // *tail* is sitting in the very footer rows the land check reads.
        let s = try await liveIdleSession(
            log: log, transcript: tallMessage,
            onEnter: #"printf 'crunching... esc to interrupt\r\n'"#, queue: queue)
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
        #expect(delivered, "the message was never confirmed delivered")

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
        #expect(count("enter", in: log) == 1)
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

    @Test func tailSignatureIsTakenFromTheLastNonEmptyLine() {
        let text = "first line of the payload\nmiddle\nthe last line that the footer keeps\n\n  \n"
        #expect(Session.tailSignature(for: text) == "the last line that the f")
        // Single-line payloads collapse to the same signature as the head, which is
        // harmless: the land check ORs the two.
        #expect(Session.tailSignature(for: "just one line") == "just one line")
        #expect(Session.tailSignature(for: "   \n\n").isEmpty)
    }
}
