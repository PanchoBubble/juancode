import Foundation
import Testing
@testable import JuancodeCore

/// End-to-end delivery tests for `Session.autoSubmit` against a fake CLI in a real
/// pty, covering the tall-seed failure that left tracked-PR prompts sitting unsent.
///
/// The fake CLI leaves the tty in its default mode, so the *terminal driver* echoes
/// a bracketed paste back as literal text with no collapsed-paste chip — exactly how
/// `claude` renders a seed too tall to fit the input box. The script itself only
/// records what it received: one line per paste, and one line per Enter that arrived
/// *after* a completed paste. The Enter is what the old footer-scoped land check
/// never got around to sending.
@Suite struct SessionSeedDeliveryTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// Rows of the bottom screen region the seed's *submit* check reads (mirrors
    /// `Session.Seed.inputRows`, which is private). The seed below renders taller
    /// than this, which is the whole point.
    private let inputRows = 16

    /// A seed whose literal rendering is taller than the input-box footer: 20 lines,
    /// each short enough not to wrap at 80 columns, so its first line (the delivery
    /// signature) sits well above the bottom `inputRows` rows once it has landed.
    /// Deliberately free of the activity detector's working/prompt tokens so the
    /// echoed text can't classify the fake session busy by itself.
    private var tallSeed: String {
        var lines = ["Track PR 4821 in juancode: watch the checks and report back"]
        for i in 1...19 {
            lines.append("Step \(i): read the changed files, then note what moved and why.")
        }
        return lines.joined(separator: "\n")
    }

    private func makeFakeCli(log: String, onPaste: String = "") -> String {
        // `read` gets whole lines because the tty is canonical, and a line ending in
        // the paste-end marker can only have been terminated by a real Enter: without
        // one the marker sits in the driver's buffer, and a *re-paste* would flush it
        // mid-line with the next paste's start marker glued on after it.
        let body = """
        LOG='\(log)'
        printf 'fake-claude ready\\r\\n'
        while IFS= read -r line; do
          case "$line" in
            *$'\\033'"[200~"*) printf 'paste\\n' >>"$LOG"; \(onPaste.isEmpty ? ":" : onPaste) ;;
          esac
          case "$line" in
            *$'\\033'"[201~") printf 'enter\\n' >>"$LOG" ;;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeLogPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-seed-\(UUID().uuidString).log").path
    }

    private func lines(of log: String) -> [String] {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func count(_ event: String, in log: String) -> Int {
        lines(of: log).filter { $0 == event }.count
    }

    /// Wait until the fake CLI has *recorded* the Enter instead of reading its log at
    /// whatever instant `autoSubmit` reports back. Nothing orders those two events:
    /// the submit check can be satisfied by the screen alone (a tall seed's signature
    /// has already scrolled out of the input box before the CR is even written), so
    /// the outcome can land while the CR is still sitting in the tty buffer.
    ///
    /// Waiting on the log is also what makes the paste count trustworthy: the child
    /// reads its input in order, so every paste it received is already written by the
    /// time the Enter line appears.
    private func awaitEnter(in log: String) async {
        await poll { self.count("enter", in: log) > 0 }
    }

    /// The default wait is derived from the delivery machine's own budget rather
    /// than from a guess about how fast the machine is: `Session.Seed` allows up to
    /// 45s to settle, 24s of re-pasting and 3 x 4s of submit retries, so a shorter
    /// wait here reports "no Enter was sent" for a delivery that is still legitimately
    /// in progress. Waiting past the whole budget can only ever be slow, never wrong.
    private func poll(_ timeout: TimeInterval = 90.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func env(script: String) -> SessionEnvironment {
        SessionEnvironment(
            resolver: FakeResolver(path: script),
            store: InMemorySessionStore(),
            discoverCliSessionId: { _, _, _ in nil }
        )
    }

    final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AutoSubmitOutcome?
        func set(_ o: AutoSubmitOutcome) { lock.withLock { value = o } }
        var outcome: AutoSubmitOutcome? { lock.withLock { value } }
    }

    @Test func tallLiteralSeedLandsOnceAndIsActuallySubmitted() async throws {
        let log = makeLogPath()
        let s = try Session.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24, env: env(script: makeFakeCli(log: log)))
        defer { s.kill() }

        let box = OutcomeBox()
        s.autoSubmit(tallSeed) { box.set($0) }
        await poll { box.outcome != nil }

        #expect(box.outcome == .submitted)

        await awaitEnter(in: log)
        // Pasted exactly once: the seed is on screen after the first attempt, so the
        // loop must not stack duplicate copies while hunting for it.
        #expect(count("paste", in: log) == 1)
        // And the Enter really went out — a "submitted" outcome with no Enter is the
        // false success this test exists for.
        #expect(count("enter", in: log) == 1)

        // The seed is on screen, but *not* in the footer the old land check read:
        // the paste is taller than the input box, so the signature sits above it.
        let signature = InitialPromptDelivery.signature(for: tallSeed)
        #expect(InitialPromptDelivery.region(s.terminalModel.visibleText(), contains: signature))
        #expect(!InitialPromptDelivery.region(s.terminalModel.bottomText(inputRows), contains: signature))
        // Rendered literally, with no collapsed-paste chip to fall back on.
        #expect(!InitialPromptDelivery.regionShowsCollapsedPaste(s.terminalModel.visibleText()))
    }

    @Test func aBusyScreenDuringThePasteStillGetsItsEnter() async throws {
        // The CLI paints its working footer while digesting the paste, which flips
        // the detector busy mid-delivery. Busy churn from our own paste is not a
        // submitted prompt, so the Enter must still be sent.
        let log = makeLogPath()
        let script = makeFakeCli(log: log, onPaste: #"printf 'crunching... esc to interrupt\r\n'"#)
        let s = try Session.create(
            provider: .claude, cwd: FileManager.default.temporaryDirectory.path,
            cols: 80, rows: 24, env: env(script: script))
        defer { s.kill() }

        let box = OutcomeBox()
        s.autoSubmit(tallSeed) { box.set($0) }
        await poll { box.outcome != nil }

        #expect(box.outcome == .submitted)
        await awaitEnter(in: log)
        #expect(count("paste", in: log) == 1)
        #expect(count("enter", in: log) == 1)
    }
}
