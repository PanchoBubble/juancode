import XCTest
import JuancodeCore
@testable import JuancodeClient

/// `RemoteLiveSession` is the handle a remote core hands the terminal surfaces.
/// What matters here is not that it forwards (it has nothing to forward to) but
/// which of its members are faithful, which are degraded, and that a degraded one
/// degrades the way it says it does rather than looking like it worked.
final class RemoteLiveSessionTests: XCTestCase {

    private func meta(_ id: String = "s1", status: SessionStatus = .running) -> SessionMeta {
        SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: "Claude · tmp", status: status,
                    exitCode: nil, createdAt: nowMs(), updatedAt: nowMs(), cliSessionId: "cli-\(id)",
                    skipPermissions: false, worktreePath: nil, usage: nil)
    }

    private func handle(_ transport: FakeTransport,
                        status: SessionStatus = .running,
                        clientId: String? = "c1") -> RemoteLiveSession {
        RemoteLiveSession(meta: meta(status: status), running: status == .running,
                          transport: transport, clientId: clientId)
    }

    // MARK: - Faithful members

    func testWriteBecomesAnInputFrame() {
        let transport = FakeTransport()
        let session = handle(transport)
        session.write("ls\r")
        session.write(Array("x".utf8))
        XCTAssertEqual(transport.inputs, ["ls\r", "x"])
    }

    /// The byte stream and its replay: a subscriber that asked for replay gets
    /// everything known so far, one that did not gets only what arrives next, and a
    /// cancelled subscriber stops.
    func testOutputSubscriptionAndReplay() {
        let transport = FakeTransport()
        let session = handle(transport)
        session.apply(output: Array("first".utf8))

        let replayed = Recorder<String>()
        let cancelReplay = session.subscribeOutput(replay: true) { replayed.record(text($0)) }
        XCTAssertEqual(replayed.all, ["first"])

        let live = Recorder<String>()
        let cancelLive = session.subscribeOutput(replay: false) { live.record(text($0)) }
        session.apply(output: Array("second".utf8))
        XCTAssertEqual(replayed.all, ["first", "second"])
        XCTAssertEqual(live.all, ["second"])

        cancelLive()
        session.apply(output: Array("third".utf8))
        XCTAssertEqual(live.all, ["second"])
        XCTAssertEqual(String(decoding: session.getScrollback(), as: UTF8.self), "firstsecondthird")
        cancelReplay()
    }

    /// An `attached` frame is a whole-state repaint: scrollback replaced, row
    /// replaced, subscribers repainted.
    func testAttachedReplacesTheStateAndRepaints() {
        let transport = FakeTransport()
        let session = handle(transport)
        session.apply(output: Array("stale".utf8))
        let painted = Recorder<String>()
        _ = session.subscribeOutput(replay: false) { painted.record(text($0)) }

        var row = meta()
        row.title = "renamed"
        session.apply(attachedScrollback: Array("fresh".utf8), meta: row)
        XCTAssertEqual(String(decoding: session.getScrollback(), as: UTF8.self), "fresh")
        XCTAssertEqual(painted.all, ["fresh"])
        XCTAssertEqual(session.meta.title, "renamed")
    }

    func testActivityAndExitReachTheirListeners() {
        let transport = FakeTransport()
        let session = handle(transport)
        let states = Recorder<String>()
        _ = session.onActivity { states.record("\($0.rawValue):\($1)") }
        let exits = Recorder<String>()
        _ = session.onExit { exits.record($0.map(String.init) ?? "nil") }

        session.apply(activity: .busy, notify: false)
        session.apply(activity: .waitingInput, notify: true)
        XCTAssertEqual(session.activity, .waitingInput)
        XCTAssertEqual(states.all, ["busy:false", "waiting_input:true"])

        session.apply(exitCode: 3)
        XCTAssertEqual(exits.all, ["3"])
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.meta.status, .exited)
        XCTAssertEqual(session.meta.exitCode, 3)
        // The exit edge is where a finished session's transcript becomes searchable:
        // nothing else writes the mirror's scrollback.
        XCTAssertEqual(transport.persisted.last?.scrollback != nil, true)
    }

    /// Activity for a session the app had written off means the core still has it:
    /// the row comes back rather than staying dead while output streams into it.
    func testActivityRevivesARowTheAppThoughtWasDead() {
        let transport = FakeTransport()
        let session = handle(transport, status: .exited)
        XCTAssertFalse(session.isRunning)
        session.apply(activity: .busy, notify: false)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.meta.status, .running)
    }

    /// The grid: a resize is sent and assumed to land, because the answer only
    /// arrives in an ack and this runs on every drag frame. A denial is remembered,
    /// so the next call reports the refusal the pane needs to know about.
    func testResizeIsOptimisticUntilTheCoreDeniesIt() {
        let transport = FakeTransport()
        let session = handle(transport)
        XCTAssertTrue(session.resizeLocal(cols: 100, rows: 30))
        XCTAssertEqual(transport.resizes.map { "\($0.cols)x\($0.rows)" }, ["100x30"])
        XCTAssertNil(session.appliedGrid() ?? nil)

        let grants = Recorder<String>()
        _ = session.onGridChange { grants.record("\($0 ?? "nil"):\($1)x\($2)") }
        session.apply(resizeAck: 100, rows: 30, applied: true, denied: false, owner: nil)
        XCTAssertEqual(session.appliedGrid()?.cols, 100)
        XCTAssertEqual(grants.all.count, 1)
        // No owner on the ack (a core without `gridOwner`) still tells this client
        // that IT holds the grid, which is the half the pane acts on.
        XCTAssertEqual(grants.all.first, "c1:100x30")

        session.apply(resizeAck: 120, rows: 40, applied: false, denied: true, owner: "someone-else")
        XCTAssertFalse(session.resizeLocal(cols: 121, rows: 41))
        XCTAssertEqual(session.gridOwner(), "someone-else")
        XCTAssertEqual(session.appliedGrid()?.cols, 100, "a denied resize must not move the applied grid")
    }

    /// Attachment is per connection, and only the client that CREATED a session is
    /// attached to it for free. A session somebody else created — an Oracle dispatch —
    /// reaches this client as a broadcast row with no bytes behind it, so the pane
    /// that mounts for it has to ask. Without the ask it stayed black forever: the
    /// core gates `output` on an attachment, and an idle CLI never emits the byte the
    /// booting hint waits for (juancode-zrxy).
    func testFirstResizeOnAnUnattachedSessionAsksForItsBytes() {
        let transport = FakeTransport()
        let session = handle(transport)
        _ = session.resizeLocal(cols: 100, rows: 30)
        XCTAssertEqual(transport.attaches.map { "\($0.cols)x\($0.rows)" }, ["100x30"],
                       "the mounting pane's grid is what we attach at")
        // The resize still goes: `attach` resizes core-side, but only `resizeAck`
        // carries the applied grid and the ownership answer.
        XCTAssertEqual(transport.resizes.map { "\($0.cols)x\($0.rows)" }, ["100x30"])

        _ = session.resizeLocal(cols: 120, rows: 40)
        _ = session.resizeLocal(cols: 121, rows: 41)
        XCTAssertEqual(transport.attaches.count, 1, "a drag is not a reason to replay the scrollback")
        XCTAssertEqual(transport.resizes.count, 3)
    }

    /// A session THIS client created is answered with `created` + `attached`, so it
    /// is already on the byte stream and a mounting pane must not ask again.
    func testAResizeAfterAnAttachedFrameDoesNotAskAgain() {
        let transport = FakeTransport()
        let session = handle(transport)
        session.apply(attachedScrollback: [], meta: meta())
        _ = session.resizeLocal(cols: 100, rows: 30)
        XCTAssertTrue(transport.attaches.isEmpty)
        XCTAssertEqual(transport.resizes.count, 1)
    }

    /// Nothing to join on a session with no pty: its pane renders the recorded
    /// replay, and an attach would only invite the core's `replay_exit`.
    func testAnExitedSessionIsNeverAttachedTo() {
        let transport = FakeTransport()
        let session = handle(transport, status: .exited)
        _ = session.resizeLocal(cols: 100, rows: 30)
        XCTAssertTrue(transport.attaches.isEmpty)
    }

    func testGridChangeBroadcastTracksOwnership() {
        let transport = FakeTransport()
        let session = handle(transport)
        let seen = Recorder<String>()
        _ = session.onGridChange { owner, _, _ in seen.record(owner ?? "nil") }

        session.apply(gridOwner: "c2", cols: 90, rows: 20)
        XCTAssertEqual(session.gridOwner(), "c2")
        XCTAssertFalse(session.resizeLocal(cols: 1, rows: 1), "another client owns it")

        session.apply(gridOwner: nil, cols: 90, rows: 20)
        XCTAssertNil(session.gridOwner())
        XCTAssertTrue(session.resizeLocal(cols: 1, rows: 1), "an unclaimed grid is claimable again")
        XCTAssertEqual(seen.all, ["c2", "nil"])
    }

    // MARK: - Degraded members

    /// `submit` is the shape of the core's paste engine without its substance: a
    /// bracketed paste, then a separate CR. What it cannot do is check the text
    /// landed in the CLI's input box, so `.delivered` means written, not verified.
    func testSubmitPastesThenSendsAnEnter() {
        let transport = FakeTransport()
        let session = handle(transport)
        let done = expectation(description: "submit reported")
        session.submit("hello") { outcome in
            XCTAssertEqual(outcome, .delivered)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(transport.inputs, ["\u{1b}[200~hello\u{1b}[201~", "\r"])
    }

    /// `insert` is the same delivery with no Enter, so the user can edit first.
    func testInsertDoesNotSendAnEnter() {
        let transport = FakeTransport()
        let session = handle(transport)
        let outcome = Recorder<PasteOutcome>()
        session.insert("draft") { outcome.record($0) }
        XCTAssertEqual(outcome.all, [.delivered])
        XCTAssertEqual(transport.inputs, ["\u{1b}[200~draft\u{1b}[201~"])
    }

    /// A paste into a session that is not running is refused loudly rather than
    /// written into a closed pty and reported as delivered.
    func testPasteIntoADeadSessionAborts() {
        let transport = FakeTransport()
        let session = handle(transport, status: .exited)
        let outcome = Recorder<PasteOutcome>()
        session.submit("hello") { outcome.record($0) }
        guard case .aborted = outcome.all.first else {
            return XCTFail("expected an abort, got \(String(describing: outcome.all.first))")
        }
        XCTAssertTrue(transport.inputs.isEmpty)
    }

    /// The opening prompt waits for the CLI to print something, which is the only
    /// "the TUI is up" signal available without the core's model.
    func testAutoSubmitWaitsForTheFirstOutput() {
        let transport = FakeTransport()
        let session = handle(transport)
        let done = expectation(description: "autoSubmit reported")
        session.autoSubmit("go") { outcome in
            XCTAssertEqual(outcome, .submitted)
            done.fulfill()
        }
        XCTAssertTrue(transport.inputs.isEmpty, "nothing is sent before the CLI has drawn")
        session.apply(output: Array("welcome".utf8))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(transport.inputs.first, "\u{1b}[200~go\u{1b}[201~")
    }

    /// No queue on the core means no flush to ask for, and nothing sent.
    func testKickQueueIsInertWithoutTheCapability() {
        let transport = FakeTransport(capabilities: [])
        let session = handle(transport)
        session.kickQueue()
        XCTAssertTrue(transport.inputs.isEmpty)
        XCTAssertTrue(transport.kills.isEmpty)
    }

    /// A core that speaks `sleepSession` is ASKED to sleep the session, and not
    /// killed: the flag has to land on the core's own row, or the core cannot tell a
    /// session the user paused from one the user ended, and its reaper, its restore
    /// plan and its liveness accounting all read the kill (juancode-nizo).
    func testMarkDormantAsksACoreThatSpeaksTheSleepFrame() {
        let transport = FakeTransport(capabilities: ["sessionSleep"])
        let session = handle(transport)
        let metaEdits = Recorder<SessionMeta>()
        _ = session.onMetaChange { metaEdits.record($0) }

        session.markDormant()
        XCTAssertEqual(transport.sleeps, ["s1"])
        XCTAssertTrue(transport.kills.isEmpty, "a pause is not a kill")
        XCTAssertTrue(session.meta.dormant)
        XCTAssertEqual(metaEdits.all.last?.dormant, true)
        XCTAssertEqual(transport.persisted.last?.meta.dormant, true)
    }

    /// And on a core without the frame it is still a pause, degraded: the kill plus
    /// the flag on the desktop's own mirror row. Worse than asking, better than a
    /// button that does nothing.
    func testMarkDormantFallsBackToAKillWithoutTheFrame() {
        let transport = FakeTransport(capabilities: [])
        let session = handle(transport)

        session.markDormant()
        XCTAssertEqual(transport.kills, ["s1"])
        XCTAssertTrue(transport.sleeps.isEmpty)
        XCTAssertTrue(session.meta.dormant)
        XCTAssertEqual(transport.persisted.last?.meta.dormant, true)
    }

    /// A rename reaches the core's own row, not only the desktop's mirror.
    ///
    /// The mirror write is not the assertion — it always happened. The frame is: the
    /// mirror is a cache the core's own `sessionMeta` broadcasts replace, and the core
    /// adopts the CLI's OSC window title several times a turn, so a rename that stopped
    /// here lasted until the next repaint (juancode-0yao).
    func testSetTitleAsksACoreThatSpeaksTheSetMetaFrame() {
        let transport = FakeTransport(capabilities: ["sessionEdit"])
        let session = handle(transport)
        let metaEdits = Recorder<SessionMeta>()
        _ = session.onMetaChange { metaEdits.record($0) }

        session.setTitle("the refactor")
        XCTAssertEqual(transport.metaWrites.count, 1)
        XCTAssertEqual(transport.metaWrites.last?.title, "the refactor")
        XCTAssertNil(
            transport.metaWrites.last?.archived,
            "a rename must not carry an archive flag it was not asked about")
        XCTAssertEqual(session.meta.title, "the refactor")
        XCTAssertEqual(metaEdits.all.last?.title, "the refactor")
        XCTAssertEqual(transport.persisted.last?.meta.title, "the refactor")
    }

    /// Archiving is the same statement about the same row, and it needs the frame for
    /// a narrower reason: nothing derives `archived`, but the core's boot backfill
    /// replaces the whole mirror from the core's list, so a flag written only in the
    /// mirror came back cleared on the next launch.
    func testSetArchivedAsksACoreThatSpeaksTheSetMetaFrame() {
        let transport = FakeTransport(capabilities: ["sessionEdit"])
        let session = handle(transport)

        session.setArchived(true)
        XCTAssertEqual(transport.metaWrites.count, 1)
        XCTAssertEqual(transport.metaWrites.last?.archived, true)
        XCTAssertNil(transport.metaWrites.last?.title)
        XCTAssertTrue(session.meta.archived)
        XCTAssertEqual(transport.persisted.last?.meta.archived, true)
    }

    /// And on a core without the frame the mirror write is what is left. Degraded, and
    /// still the honest answer: the alternative is a rename sheet that refuses.
    func testSetMetaFallsBackToTheMirrorRowWithoutTheFrame() {
        let transport = FakeTransport(capabilities: [])
        let session = handle(transport)

        session.setTitle("named anyway")
        session.setArchived(true)
        XCTAssertTrue(transport.metaWrites.isEmpty)
        XCTAssertEqual(session.meta.title, "named anyway")
        XCTAssertTrue(session.meta.archived)
        XCTAssertEqual(transport.persisted.last?.meta.title, "named anyway")
        XCTAssertEqual(transport.persisted.last?.meta.archived, true)
    }

    /// The frame did not replace the mirror write, and must not: the mirror row is
    /// what the sidebar redraws from this instant, and the core's confirming
    /// `sessionMeta` is a round trip away. The row is written first and the UI is
    /// told, and neither write touches the scrollback.
    func testTitleAndArchiveStillWriteTheMirrorRowFirst() {
        let transport = FakeTransport(capabilities: ["sessionEdit"])
        let session = handle(transport)
        let metaEdits = Recorder<SessionMeta>()
        _ = session.onMetaChange { metaEdits.record($0) }

        session.setTitle("pinned")
        session.setArchived(true)
        XCTAssertEqual(session.meta.title, "pinned")
        XCTAssertTrue(session.meta.archived)
        XCTAssertEqual(metaEdits.all.map(\.title), ["pinned", "pinned"])
        XCTAssertEqual(transport.persisted.count, 2)
        XCTAssertTrue(transport.persisted.allSatisfy { $0.scrollback == nil },
                      "a meta edit must not rewrite the scrollback")
        XCTAssertEqual(transport.metaWrites.count, 2, "one frame per edit, no batching")
        XCTAssertTrue(transport.inputs.isEmpty)
        XCTAssertTrue(transport.kills.isEmpty)
    }

    /// A `sessionMeta` frame, on a core that grows the capability, replaces the row
    /// wholesale and tells the UI. Same path, driven by the core instead of by us.
    func testSessionMetaFrameReplacesTheRow() {
        let transport = FakeTransport(capabilities: ["sessionMeta"])
        let session = handle(transport)
        let metaEdits = Recorder<SessionMeta>()
        _ = session.onMetaChange { metaEdits.record($0) }
        var row = meta()
        row.title = "derived by the CLI"
        session.apply(meta: row)
        XCTAssertEqual(session.meta.title, "derived by the CLI")
        XCTAssertEqual(metaEdits.all.count, 1)
        // Identical meta is not an edge: a re-broadcast must not churn the UI.
        session.apply(meta: row)
        XCTAssertEqual(metaEdits.all.count, 1)
    }

    /// A pid from another process is not addressable, and the spec says so for
    /// good: nil here is the contract, not a gap.
    func testChildPidIsAlwaysNil() {
        XCTAssertNil(handle(FakeTransport()).childPid)
    }

    /// The model seed is a raw replay on this side, and a repaint is refused when
    /// the core has confirmed a different grid — the one width guard that can be
    /// applied without holding the model.
    func testRepaintIsGuardedByTheAckedGrid() {
        let transport = FakeTransport()
        let session = handle(transport)
        session.apply(output: Array("painted".utf8))
        session.apply(resizeAck: 80, rows: 24, applied: true, denied: false, owner: nil)

        let matched = Recorder<String>()
        session.repaintFromModel(matching: (cols: 80, rows: 24)) { matched.record(text($0)) }
        XCTAssertEqual(matched.all, ["painted"])

        let mismatched = Recorder<String>()
        session.repaintFromModel(matching: (cols: 120, rows: 40)) { mismatched.record(text($0)) }
        XCTAssertTrue(mismatched.all.isEmpty, "a repaint at the wrong grid is what garbles a pane")

        let seeded = Recorder<String>()
        _ = session.subscribeFromModelSeed { seeded.record(text($0)) }
        XCTAssertEqual(seeded.all, ["painted"])
    }

    /// The handle stays inside its scrollback cap, like the core's own ring: a
    /// remote core's session must not grow this process without bound.
    func testScrollbackIsCapped() {
        let transport = FakeTransport()
        let session = RemoteLiveSession(meta: meta(), running: true, transport: transport,
                                        clientId: nil, scrollbackLimit: 8)
        session.apply(output: Array("0123456789".utf8))
        XCTAssertEqual(String(decoding: session.getScrollback(), as: UTF8.self), "23456789")
    }
}

/// Collects what a listener was handed, off whatever thread it ran on.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func record(_ item: T) { lock.withLock { items.append(item) } }

    var all: [T] { lock.withLock { items } }
}

/// Decoded output bytes, since every assertion here is about text.
private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

/// The connection, as one session sees it: a recorder.
final class FakeTransport: RemoteSessionTransport, @unchecked Sendable {
    let backendName = "rust"
    private let capabilities: Set<String>
    private let lock = NSLock()

    private var recordedInputs: [String] = []
    private var recordedResizes: [(cols: Int, rows: Int)] = []
    private var recordedAttaches: [(cols: Int, rows: Int)] = []
    private var recordedKills: [String] = []
    private var recordedSleeps: [String] = []
    private var recordedMetaWrites: [(title: String?, archived: Bool?)] = []
    private var recordedPersists: [(meta: SessionMeta, scrollback: [UInt8]?)] = []

    init(capabilities: Set<String> = ["inputAck", "resizeAck", "screen", "adoptExternal"]) {
        self.capabilities = capabilities
    }

    var inputs: [String] { lock.withLock { recordedInputs } }
    var resizes: [(cols: Int, rows: Int)] { lock.withLock { recordedResizes } }
    var attaches: [(cols: Int, rows: Int)] { lock.withLock { recordedAttaches } }
    var kills: [String] { lock.withLock { recordedKills } }
    var sleeps: [String] { lock.withLock { recordedSleeps } }
    var metaWrites: [(title: String?, archived: Bool?)] { lock.withLock { recordedMetaWrites } }
    var persisted: [(meta: SessionMeta, scrollback: [UInt8]?)] { lock.withLock { recordedPersists } }

    func supports(_ capability: CoreCapability) -> Bool { capabilities.contains(capability.rawValue) }

    func sendInput(sessionId: String, text: String) {
        lock.withLock { recordedInputs.append(text) }
    }

    func sendResize(sessionId: String, cols: Int, rows: Int) -> Int {
        lock.withLock { recordedResizes.append((cols, rows)); return recordedResizes.count }
    }

    func sendAttach(sessionId: String, cols: Int, rows: Int) {
        lock.withLock { recordedAttaches.append((cols, rows)) }
    }

    func sendKill(sessionId: String) {
        lock.withLock { recordedKills.append(sessionId) }
    }

    /// Keyed on the raw capability string, the way `RustCoreClient` keys it: there is
    /// no `CoreCapability` case for `sessionSleep`, because the Swift core sleeps a
    /// session with no frame at all.
    func sendSleep(sessionId: String) -> Bool {
        guard capabilities.contains("sessionSleep") else { return false }
        lock.withLock { recordedSleeps.append(sessionId) }
        return true
    }

    /// Keyed on the raw capability string too, for the same reason `sendSleep` is.
    @discardableResult
    func sendSetMeta(sessionId: String, title: String?, archived: Bool?) -> Bool {
        guard capabilities.contains("sessionEdit") else { return false }
        lock.withLock { recordedMetaWrites.append((title, archived)) }
        return true
    }

    func persist(_ meta: SessionMeta, scrollback: [UInt8]?) {
        lock.withLock { recordedPersists.append((meta, scrollback)) }
    }
}
