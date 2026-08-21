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

    /// Sleep has no frame: it degrades to a kill plus the dormant flag, which is
    /// what dormant means — pty gone, row resumable.
    func testMarkDormantKillsAndFlagsTheRow() {
        let transport = FakeTransport()
        let session = handle(transport)
        let metaEdits = Recorder<SessionMeta>()
        _ = session.onMetaChange { metaEdits.record($0) }

        session.markDormant()
        XCTAssertEqual(transport.kills, ["s1"])
        XCTAssertTrue(session.meta.dormant)
        XCTAssertEqual(metaEdits.all.last?.dormant, true)
        XCTAssertEqual(transport.persisted.last?.meta.dormant, true)
    }

    /// A pinned title and an archive flip are desktop-side facts on a core with no
    /// frame to carry them: the mirror row is written and the UI is told, and
    /// nothing is sent to the core pretending otherwise.
    func testTitleAndArchiveWriteTheMirrorOnly() {
        let transport = FakeTransport()
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
    private var recordedKills: [String] = []
    private var recordedPersists: [(meta: SessionMeta, scrollback: [UInt8]?)] = []

    init(capabilities: Set<String> = ["inputAck", "resizeAck", "screen", "adoptExternal"]) {
        self.capabilities = capabilities
    }

    var inputs: [String] { lock.withLock { recordedInputs } }
    var resizes: [(cols: Int, rows: Int)] { lock.withLock { recordedResizes } }
    var kills: [String] { lock.withLock { recordedKills } }
    var persisted: [(meta: SessionMeta, scrollback: [UInt8]?)] { lock.withLock { recordedPersists } }

    func supports(_ capability: CoreCapability) -> Bool { capabilities.contains(capability.rawValue) }

    func sendInput(sessionId: String, text: String) {
        lock.withLock { recordedInputs.append(text) }
    }

    func sendResize(sessionId: String, cols: Int, rows: Int) -> Int {
        lock.withLock { recordedResizes.append((cols, rows)); return recordedResizes.count }
    }

    func sendKill(sessionId: String) {
        lock.withLock { recordedKills.append(sessionId) }
    }

    func persist(_ meta: SessionMeta, scrollback: [UInt8]?) {
        lock.withLock { recordedPersists.append((meta, scrollback)) }
    }
}
