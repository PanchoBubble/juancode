import XCTest
import JuancodeCore
@testable import JuancodeClient

/// `RustCoreClient` against a REAL `juancoded`, because a mock cannot tell us
/// whether the frames we send are the frames it expects.
///
/// Opt-in, and skipped otherwise: it needs a daemon, and a daemon spawns ptys. Run
/// it by hand against one booted on its own port and its own data dir, never
/// against :4280 or :4281 (a developer's live app and sidecar own those, and
/// driving them would create and kill real sessions):
///
///     cargo build -p juancoded
///     JUANCODED_PORT=4291 \
///     JUANCODED_SOCKET=/tmp/juancoded-live.sock \
///     JUANCODED_DATA_DIR=/tmp/juancoded-live \
///     JUANCODE_CLAUDE_BIN=apps/wire-conformance/fixtures/fake-agent.sh \
///     ./apps/juancoded/target/debug/juancoded &
///
///     JUANCODE_RUST_LIVE_URL=http://127.0.0.1:4291 \
///     swift test --filter RustCoreLiveTests
///
/// The provider binary is the conformance suite's fake agent, so no real CLI is
/// launched: it reads one command per line and prints exactly what was asked for.
final class RustCoreLiveTests: XCTestCase {
    private var core: RustCoreClient!
    private var mirrorPath: String!

    override func setUpWithError() throws {
        guard let url = ProcessInfo.processInfo.environment["JUANCODE_RUST_LIVE_URL"],
              !url.isEmpty else {
            throw XCTSkip("set JUANCODE_RUST_LIVE_URL to a booted juancoded to run these")
        }
        mirrorPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-rust-live-\(UUID().uuidString).db")
        core = try RustCoreClient.connect(baseURL: url, mirrorPath: mirrorPath, timeout: 5)
    }

    override func tearDownWithError() throws {
        core?.shutdown()
        core = nil
        guard let mirrorPath else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: mirrorPath + suffix)
        }
    }

    /// The handshake is the whole basis of the gating, so read it from the real core
    /// and print it: this is the number the report quotes.
    func testHandshakeReportsTheDaemonsCapabilities() {
        XCTAssertEqual(core.info.protocolVersion, 1)
        XCTAssertTrue(core.isConnected)
        print("juancoded capabilities: \(core.info.capabilities.sorted().joined(separator: ", "))")
        print("juancoded missing: \(core.missingCapabilities.map(\.rawValue).joined(separator: ", "))")
        for required: CoreCapability in [.inputAck, .resizeAck, .screen] {
            XCTAssertTrue(core.supports(required), required.rawValue)
        }
    }

    /// A capability the daemon does not advertise throws instead of no-oping, and
    /// the error says which capability and what it costs.
    func testMissingCapabilitiesThrowRatherThanPretend() {
        if !core.supports(.editor) {
            XCTAssertThrowsError(try core.openEditorPty(cwd: "/tmp", file: "/tmp/x", cols: 80, rows: 24)) {
                XCTAssertEqual(($0 as? CoreCapabilityError)?.capability, .editor)
            }
        }
        if !core.supports(.terminal) {
            XCTAssertThrowsError(try core.openTerminalPty(cwd: "/tmp", cols: 80, rows: 24)) {
                XCTAssertEqual(($0 as? CoreCapabilityError)?.capability, .terminal)
            }
        }
        if !core.supports(.restartFresh) {
            // The frame exists in the spec now, so this is a capability the daemon
            // has yet to implement rather than an operation with nowhere to go.
            let dead = SessionMeta.adopting(provider: .claude, cliSessionId: UUID().uuidString,
                                            cwd: "/tmp", startMs: 0)
            XCTAssertThrowsError(try core.restartFresh(dead, cols: 80, rows: 24)) {
                XCTAssertEqual(($0 as? CoreCapabilityError)?.capability, .restartFresh)
            }
        }
        if !core.supports(.queue) {
            XCTAssertTrue(core.queuedMessages("anything").isEmpty)
            XCTAssertFalse(core.dequeueMessage("anything", messageId: "m"))
        }
        if !core.supports(.trackedPrs) {
            let empty = expectation(description: "an empty watch list")
            let core = core!
            Task {
                _ = await core.subscribeTrackedPrs { event in
                    if case .trackedPrs(let list) = event, list.isEmpty { empty.fulfill() }
                }
            }
            wait(for: [empty], timeout: 5)
        }
    }

    /// Reactivating a session the daemon has never heard of has to fail with the
    /// core's own message, not hang and not silently answer a handle.
    func testResumingAnUnknownSessionFails() {
        let ghost = SessionMeta(id: "not-a-session-\(UUID().uuidString)", provider: .claude,
                               cwd: "/tmp", title: "ghost", status: .exited, exitCode: 0,
                               createdAt: nowMs(), updatedAt: nowMs(), cliSessionId: nil,
                               skipPermissions: false, worktreePath: nil, usage: nil)
        XCTAssertThrowsError(try core.resume(ghost, cols: 80, rows: 24, priorScrollback: [])) { error in
            print("resume of an unknown session: \(error.localizedDescription)")
        }
    }

    /// The end-to-end path the whole ticket is about: create a session in the
    /// daemon, get a `LiveSession` back, drive its pty with `input`, see its bytes
    /// arrive as `output`, resize it, watch its activity, and kill it.
    ///
    /// Needs a provider binary the daemon can spawn; with the conformance fake
    /// agent that is deterministic and costs nothing.
    func testCreateDriveResizeAndKillAgainstTheDaemon() throws {
        let session = try core.create(provider: .claude, cwd: NSTemporaryDirectory(),
                                      cols: 100, rows: 30,
                                      opts: SpawnOptions(skipPermissions: true, model: nil),
                                      worktreePath: nil, dispatchId: nil,
                                      initialInput: nil, onSeedFailure: nil)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.meta.provider, .claude)
        // The row reached the desktop mirror, which is what the sidebar reads.
        XCTAssertEqual(core.session(session.id)?.id, session.id)
        XCTAssertEqual(core.sessions().map(\.id), [session.id])
        XCTAssertEqual(core.liveSessions().count, 1)

        let echoed = expectation(description: "the pty echoed our input back")
        let cancel = session.subscribeOutput(replay: false) { bytes in
            if String(decoding: bytes, as: UTF8.self).contains("juancode-52e8-2") { echoed.fulfill() }
        }
        session.write("ECHO juancode-52e8-2\r")
        wait(for: [echoed], timeout: 10)
        cancel()

        // A resize is arbitrated by the daemon and acked; the applied grid is what
        // the pty actually runs at.
        XCTAssertTrue(session.resizeLocal(cols: 90, rows: 25))
        let acked = expectation(description: "the resize was acked")
        Task { [session] in
            for _ in 0..<50 {
                if session.appliedGrid() != nil { acked.fulfill(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        wait(for: [acked], timeout: 10)
        XCTAssertEqual(session.appliedGrid()?.cols, 90)
        XCTAssertEqual(session.appliedGrid()?.rows, 25)

        let exited = expectation(description: "the session exited")
        _ = session.onExit { _ in exited.fulfill() }
        session.kill()
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(session.isRunning)
        // The exit edge is what makes a finished session searchable in the mirror.
        XCTAssertEqual(core.session(session.id)?.status, .exited)
        XCTAssertNotNil(core.storedScrollback(session.id))
    }

    /// A second client attaching to the same session is what grid arbitration is
    /// for, and on a `gridOwner` core the app can name who holds it.
    func testGridOwnershipIsVisibleWhenTheCoreAdvertisesIt() throws {
        try XCTSkipUnless(core.supports(.gridOwner), "this daemon has no gridOwner capability")
        let session = try core.create(provider: .claude, cwd: NSTemporaryDirectory(),
                                      cols: 100, rows: 30,
                                      opts: SpawnOptions(skipPermissions: true, model: nil),
                                      worktreePath: nil, dispatchId: nil,
                                      initialInput: nil, onSeedFailure: nil)
        defer { session.kill() }
        XCTAssertTrue(session.resizeLocal(cols: 95, rows: 28))
        let owned = expectation(description: "the grid names an owner")
        Task { [session] in
            for _ in 0..<50 {
                if session.gridOwner() != nil { owned.fulfill(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        wait(for: [owned], timeout: 10)
        print("grid owner after our resize: \(session.gridOwner() ?? "nil")")
    }

    /// The dispatch path, end to end: a prompt handed to `create` is delivered by
    /// the DAEMON — pasted, confirmed on screen, then submitted with its own Enter.
    ///
    /// The fake agent only acts on a line it has been given in full, so the title it
    /// sets is proof of both halves: that the text arrived, and that an Enter
    /// followed it. This is the regression the whole change is about — the client
    /// used to leave `initialInput` off the frame and paste from the app instead,
    /// which typed the prompt into a still-booting TUI and never submitted it.
    func testAPromptOnTheCreateIsDeliveredAndSubmittedByTheDaemon() throws {
        try XCTSkipUnless(core.supports(.sessionMeta), "this daemon has no sessionMeta capability")
        let seedFailed = expectation(description: "no seed failure was reported")
        seedFailed.isInverted = true
        let session = try core.create(provider: .claude, cwd: NSTemporaryDirectory(),
                                      cols: 100, rows: 30,
                                      opts: SpawnOptions(skipPermissions: true, model: nil),
                                      worktreePath: nil, dispatchId: nil,
                                      initialInput: "TITLE seeded-by-the-core",
                                      onSeedFailure: { _, reason in
                                          XCTFail("the seed was not delivered: \(reason)")
                                          seedFailed.fulfill()
                                      })
        defer { session.kill() }
        let ran = expectation(description: "the seeded line was submitted, not just typed")
        _ = session.onMetaChange { meta in
            if meta.title.contains("seeded-by-the-core") { ran.fulfill() }
        }
        wait(for: [ran], timeout: 60)
        wait(for: [seedFailed], timeout: 1)
    }

    /// On a `sessionMeta` core, a title the CLI sets for itself reaches the app
    /// without re-attaching — the frame that stops a sidebar row being frozen.
    func testSessionMetaFrameCarriesTheCliTitle() throws {
        try XCTSkipUnless(core.supports(.sessionMeta), "this daemon has no sessionMeta capability")
        let session = try core.create(provider: .claude, cwd: NSTemporaryDirectory(),
                                      cols: 100, rows: 30,
                                      opts: SpawnOptions(skipPermissions: true, model: nil),
                                      worktreePath: nil, dispatchId: nil,
                                      initialInput: nil, onSeedFailure: nil)
        defer { session.kill() }
        let renamed = expectation(description: "the CLI's own title arrived")
        _ = session.onMetaChange { meta in
            if meta.title.contains("named-by-the-cli") { renamed.fulfill() }
        }
        session.write("TITLE named-by-the-cli\r")
        wait(for: [renamed], timeout: 10)
        XCTAssertTrue(core.session(session.id)?.title.contains("named-by-the-cli") == true,
                      "the mirror row follows the frame")
    }
}
