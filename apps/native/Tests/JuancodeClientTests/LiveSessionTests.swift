import XCTest
import JuancodeCore
import JuancodeServer
@testable import JuancodeClient

/// `LiveSession` exists so a core that is not an object in this process can still
/// drive the terminal surfaces. The thing worth pinning is therefore not what
/// `Session` does (that is `JuancodeCoreTests`) but that the protocol is
/// implementable by something which is NOT a `Session`, and that everything the
/// surfaces rely on survives the indirection: the subscribe/cancel contract, the
/// grid arbitration the pane reads back, the default-argument forms the app calls,
/// and the object identity the keep-alive pane pool keys on.
///
/// `WireBackedSession` below is that something. It answers every member from
/// buffers and listener lists the way a wire-frame implementation would, with no
/// pty and no core anywhere in it.
final class LiveSessionTests: XCTestCase {

    // MARK: - Conformance

    /// The in-process core still satisfies the protocol, so `SwiftCoreClient` keeps
    /// forwarding rather than adapting. The call is the assertion: it only
    /// type-checks while `Session: LiveSession`.
    func testSessionConformsToLiveSession() {
        requiresLiveSession(Session.self)
    }

    /// Nothing in the protocol needs a `Session`: a handle assembled from buffers
    /// answers the whole surface.
    func testAnImplementationWithoutASessionSatisfiesTheProtocol() {
        let handle: any LiveSession = WireBackedSession(id: "s1")
        XCTAssertEqual(handle.id, "s1")
        XCTAssertEqual(handle.meta.id, "s1")
        XCTAssertTrue(handle.isRunning)
        XCTAssertEqual(handle.activity, .idle)
        XCTAssertNil(handle.childPid)
    }

    // MARK: - Output

    func testSubscribeOutputReplaysThenStreamsUntilCancelled() {
        let session = WireBackedSession(id: "s1")
        session.appendScrollback("history")

        let seen = ByteRecorder()
        let cancel = session.subscribeOutput(replay: true) { seen.record($0) }
        session.emitOutput("live")
        cancel()
        session.emitOutput("after cancel")

        XCTAssertEqual(seen.texts(), ["history", "live"])
    }

    func testSubscribeOutputWithoutReplayOnlySeesNewBytes() {
        let session = WireBackedSession(id: "s1")
        session.appendScrollback("history")

        let seen = ByteRecorder()
        let cancel = session.subscribeOutput(replay: false) { seen.record($0) }
        session.emitOutput("live")
        cancel()

        XCTAssertEqual(seen.texts(), ["live"])
    }

    /// The model seed is what a freshly mounted pane paints from: one screen, not
    /// the whole history.
    func testSubscribeFromModelSeedDeliversTheScreenNotTheScrollback() {
        let session = WireBackedSession(id: "s1")
        session.appendScrollback("history")
        session.screen = "one screen"

        let seen = ByteRecorder()
        let cancel = session.subscribeFromModelSeed { seen.record($0) }
        session.emitOutput("live")
        cancel()

        XCTAssertEqual(seen.texts(), ["one screen", "live"])
    }

    /// The width guard is the whole point of `repaintFromModel(matching:)`: a
    /// repaint parsed at one grid must never be handed to a view at another.
    func testRepaintIsDroppedWhenTheModelHasMovedOffTheRequestedGrid() {
        let session = WireBackedSession(id: "s1")
        session.screen = "screen"
        session.grid = (cols: 100, rows: 30)

        let matching = ByteRecorder()
        session.repaintFromModel(matching: (cols: 100, rows: 30)) { matching.record($0) }
        XCTAssertEqual(matching.texts(), ["screen"])

        let drifted = ByteRecorder()
        session.repaintFromModel(matching: (cols: 80, rows: 24)) { drifted.record($0) }
        XCTAssertTrue(drifted.texts().isEmpty)

        let unguarded = ByteRecorder()
        session.repaintFromModel(matching: nil) { unguarded.record($0) }
        XCTAssertEqual(unguarded.texts(), ["screen"])
    }

    // MARK: - Grid

    /// What the pane does on every layout pass: claim the grid, read back what the
    /// pty actually took, release on unmount.
    func testGridClaimReadBackAndRelease() {
        let session = WireBackedSession(id: "s1")
        XCTAssertNil(session.gridOwner())

        XCTAssertTrue(session.resizeLocal(cols: 120, rows: 40))
        XCTAssertEqual(session.gridOwner(), GridArbiter.localOwner)
        XCTAssertEqual(session.appliedGrid()?.cols, 120)
        XCTAssertEqual(session.appliedGrid()?.rows, 40)

        session.releaseGrid(owner: GridArbiter.localOwner)
        XCTAssertNil(session.gridOwner())
    }

    /// A denied resize is the remote-owner case: the pane must be told no rather
    /// than silently drifting from the pty.
    func testResizeIsDeniedWhileAnotherOwnerHoldsTheGrid() {
        let session = WireBackedSession(id: "s1")
        session.claim(owner: "phone", cols: 80, rows: 24)

        XCTAssertFalse(session.resizeLocal(cols: 120, rows: 40))
        XCTAssertEqual(session.gridOwner(), "phone")
        XCTAssertEqual(session.appliedGrid()?.cols, 80)
    }

    func testGridChangeSubscriberSeesGrantsAndReleasesUntilCancelled() {
        let session = WireBackedSession(id: "s1")
        let seen = GridRecorder()
        let cancel = session.onGridChange { owner, cols, rows in seen.record(owner, cols, rows) }

        session.resizeLocal(cols: 120, rows: 40)
        session.releaseGrid(owner: GridArbiter.localOwner)
        cancel()
        session.resizeLocal(cols: 90, rows: 30)

        XCTAssertEqual(seen.changes(), [
            "\(GridArbiter.localOwner):120x40",
            "nil:120x40",
        ])
    }

    // MARK: - Listeners

    func testActivityExitAndMetaSubscribersAllCancelIndependently() {
        let session = WireBackedSession(id: "s1")
        let states = StateRecorder()

        let activityCancel = session.onActivity { state, notify in
            states.record("activity:\(state.rawValue):\(notify)")
        }
        let metaCancel = session.onMetaChange { meta in states.record("meta:\(meta.title)") }
        let exitCancel = session.onExit { code in states.record("exit:\(code ?? -1)") }

        session.emitActivity(.busy, notify: false)
        session.setTitle("renamed")
        activityCancel()
        session.emitActivity(.idle, notify: true)
        session.emitExit(0)
        metaCancel()
        exitCancel()
        session.setTitle("ignored")
        session.emitExit(1)

        XCTAssertEqual(states.events(), ["activity:busy:false", "meta:renamed", "exit:0"])
        XCTAssertEqual(session.meta.title, "ignored")
    }

    func testArchiveFlipIsAMetaChange() {
        let session = WireBackedSession(id: "s1")
        let states = StateRecorder()
        let cancel = session.onMetaChange { meta in states.record("archived:\(meta.archived)") }
        session.setArchived(true)
        cancel()
        XCTAssertEqual(states.events(), ["archived:true"])
        XCTAssertTrue(session.meta.archived)
    }

    // MARK: - Input

    /// Protocol requirements carry no default arguments, so the app's
    /// `submit(text)` / `insert(text)` / `autoSubmit(text)` call sites go through
    /// the extension. They must land the same delivery, just with no result
    /// callback.
    func testFireAndForgetInputFormsForwardWithNoResultCallback() {
        let session = WireBackedSession(id: "s1")
        let handle: any LiveSession = session

        handle.submit("one")
        handle.insert("two")
        handle.autoSubmit("three")
        handle.write("raw")
        handle.write(Array("bytes".utf8))
        handle.kickQueue()

        XCTAssertEqual(session.calls(), [
            "submit:one:noResult",
            "insert:two:noResult",
            "autoSubmit:three:noResult",
            "write:raw",
            "write:bytes",
            "kickQueue",
        ])
    }

    func testInputFormsWithAResultCallbackStillReportTheOutcome() {
        let session = WireBackedSession(id: "s1")
        let handle: any LiveSession = session
        let states = StateRecorder()

        handle.submit("one") { states.record("submit:\($0)") }
        handle.insert("two") { states.record("insert:\($0)") }
        handle.autoSubmit("three") { states.record("auto:\($0)") }

        XCTAssertEqual(states.events(), [
            "submit:delivered", "insert:delivered", "auto:submitted",
        ])
    }

    // MARK: - Lifecycle

    func testKillAndSleepAreDistinctAndBothStopRunning() {
        let killed = WireBackedSession(id: "s1")
        killed.kill()
        XCTAssertFalse(killed.isRunning)
        XCTAssertEqual(killed.calls(), ["kill"])

        let slept = WireBackedSession(id: "s2")
        slept.markDormant()
        XCTAssertFalse(slept.isRunning)
        XCTAssertEqual(slept.calls(), ["markDormant"])
    }

    // MARK: - Pane-pool erasure

    /// The keep-alive pool is parameterised on `AnyObject` because Swift will not
    /// take `any LiveSession` where a class is required. Erasing must not disturb
    /// what the pool actually keys on, so: the handle comes back the same object,
    /// and a pane keeps its identity across an unrelated visit.
    func testPooledHandleSurvivesErasureWithItsIdentity() {
        let session = WireBackedSession(id: "s1")
        var pool = LivePanePool<AnyObject>(cap: 2)
        pool.noteVisible("s1", refresh: 0) { _ in session }

        XCTAssertEqual(pool.entries.count, 1)
        XCTAssertTrue(pool.entries[0].live === session)
        let identity = pool.entries[0].id

        pool.noteVisible("s1", refresh: 1) { _ in session }
        XCTAssertEqual(pool.entries[0].id, identity, "an unchanged handle must keep its pane")
    }

    /// The case the pool exists to catch: a permissions flip mints a new handle
    /// behind the same session id, and the mounted pane is subscribed to the old
    /// one, so it has to be re-keyed. Identity is compared through `AnyObject`
    /// after erasure, which is the part this pins.
    func testASwappedHandleReKeysItsPane() {
        let first = WireBackedSession(id: "s1")
        let second = WireBackedSession(id: "s1")
        var pool = LivePanePool<AnyObject>(cap: 2)

        pool.noteVisible("s1", refresh: 0) { _ in first }
        let before = pool.entries[0].id

        pool.noteVisible("s1", refresh: 1) { _ in second }
        XCTAssertEqual(pool.entries.count, 1)
        XCTAssertTrue(pool.entries[0].live === second)
        XCTAssertNotEqual(pool.entries[0].id, before)

        pool.prune { _ in nil }
        XCTAssertTrue(pool.entries.isEmpty, "a dead handle must not linger mounted")
    }

    /// `pooledSession` is the erasing form of `liveSession` the pool's resolve
    /// closures call, and it must agree with it rather than being a second lookup.
    func testPooledSessionAgreesWithLiveSession() throws {
        let dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("juancode-pool-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
        let core = SwiftCoreClient(state: try AppState(dbPath: dbPath))
        XCTAssertNil(core.liveSession("nope"))
        XCTAssertNil(core.pooledSession("nope"))
    }
}

/// Compile-time conformance check, no runtime behaviour.
private func requiresLiveSession<S: LiveSession>(_: S.Type) {}

// MARK: - A LiveSession that is not a Session

/// What a remote core's per-session client looks like: buffers, listener lists and
/// a grid owner, with no pty and no `JuancodeCore.Session` behind it. The frames a
/// wire implementation would drive it from are named on each `emit`.
private final class WireBackedSession: LiveSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _meta: SessionMeta
    private var scrollback: [UInt8] = []
    private var _calls: [String] = []
    private var outputListeners: [Int: OutputListener] = [:]
    private var activityListeners: [Int: ActivityListener] = [:]
    private var exitListeners: [Int: ExitListener] = [:]
    private var gridListeners: [Int: GridChangeListener] = [:]
    private var metaListeners: [Int: MetaChangeListener] = [:]
    private var nextToken = 0
    private var owner: String?

    /// The headless model's current screen, as a `screen` frame with `reset: true`
    /// would carry it.
    var screen = ""
    /// The grid the pty runs at, as `resizeAck` reports it.
    var grid: (cols: Int, rows: Int)? = (cols: 80, rows: 24)

    init(id: String) {
        _meta = SessionMeta(id: id, provider: .claude, cwd: "/tmp", title: "fake",
                            status: .running, exitCode: nil, createdAt: nowMs(),
                            updatedAt: nowMs(), cliSessionId: nil, skipPermissions: false,
                            worktreePath: nil, usage: nil)
    }

    // MARK: test hooks

    func calls() -> [String] { lock.withLock { _calls } }

    func appendScrollback(_ text: String) {
        lock.withLock { scrollback.append(contentsOf: Array(text.utf8)) }
    }

    /// An `output` frame.
    func emitOutput(_ text: String) {
        let bytes = Array(text.utf8)
        let listeners = lock.withLock { () -> [OutputListener] in
            scrollback.append(contentsOf: bytes)
            return Array(outputListeners.values)
        }
        for l in listeners { l(bytes) }
    }

    /// An `activity` frame.
    func emitActivity(_ state: SessionActivity, notify: Bool) {
        for l in lock.withLock({ Array(activityListeners.values) }) { l(state, notify) }
    }

    /// An `exit` frame.
    func emitExit(_ code: Int?) {
        for l in lock.withLock({ Array(exitListeners.values) }) { l(code) }
    }

    /// A `resizeAck` granted to somebody else.
    func claim(owner: String, cols: Int, rows: Int) {
        lock.withLock {
            self.owner = owner
            grid = (cols: cols, rows: rows)
        }
    }

    // MARK: LiveSession

    var meta: SessionMeta { lock.withLock { _meta } }
    var id: String { lock.withLock { _meta.id } }
    var isRunning: Bool { lock.withLock { _meta.status == .running } }
    var activity: SessionActivity { .idle }
    var childPid: pid_t? { nil }

    func write(_ bytes: [UInt8]) { record("write:\(String(decoding: bytes, as: UTF8.self))") }

    func write(_ text: String) { record("write:\(text)") }

    func submit(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?) {
        record("submit:\(text):\(onResult == nil ? "noResult" : "result")")
        onResult?(.delivered)
    }

    func insert(_ text: String, onResult: (@Sendable (PasteOutcome) -> Void)?) {
        record("insert:\(text):\(onResult == nil ? "noResult" : "result")")
        onResult?(.delivered)
    }

    func autoSubmit(_ text: String, onResult: (@Sendable (AutoSubmitOutcome) -> Void)?) {
        record("autoSubmit:\(text):\(onResult == nil ? "noResult" : "result")")
        onResult?(.submitted)
    }

    func kickQueue() { record("kickQueue") }

    @discardableResult
    func resizeLocal(cols: Int, rows: Int) -> Bool {
        let granted = lock.withLock { () -> Bool in
            guard owner == nil || owner == GridArbiter.localOwner else { return false }
            owner = GridArbiter.localOwner
            grid = (cols: cols, rows: rows)
            return true
        }
        if granted { emitGrid(owner: GridArbiter.localOwner, cols: cols, rows: rows) }
        return granted
    }

    func appliedGrid() -> (cols: Int, rows: Int)? { lock.withLock { grid } }

    func releaseGrid(owner: String) {
        let released = lock.withLock { () -> (cols: Int, rows: Int)? in
            guard self.owner == owner else { return nil }
            self.owner = nil
            return grid
        }
        if let released { emitGrid(owner: nil, cols: released.cols, rows: released.rows) }
    }

    func gridOwner() -> String? { lock.withLock { owner } }

    @discardableResult
    func onGridChange(_ listener: @escaping GridChangeListener) -> Cancel {
        subscribe(.grid) { gridListeners[$0] = listener }
    }

    func getScrollback() -> [UInt8] { lock.withLock { scrollback } }

    @discardableResult
    func subscribeOutput(replay: Bool, _ listener: @escaping OutputListener) -> Cancel {
        let replayBytes = lock.withLock { () -> [UInt8] in replay ? scrollback : [] }
        let cancel = subscribe(.output) { outputListeners[$0] = listener }
        if !replayBytes.isEmpty { listener(replayBytes) }
        return cancel
    }

    @discardableResult
    func subscribeFromModelSeed(_ onBytes: @escaping OutputListener) -> Cancel {
        let seed = Array(screen.utf8)
        let cancel = subscribe(.output) { outputListeners[$0] = onBytes }
        if !seed.isEmpty { onBytes(seed) }
        return cancel
    }

    func repaintFromModel(matching grid: (cols: Int, rows: Int)?,
                          _ onBytes: @escaping OutputListener) {
        if let grid, let current = appliedGrid(),
           current.cols != grid.cols || current.rows != grid.rows { return }
        onBytes(Array(screen.utf8))
    }

    func kill() {
        record("kill")
        lock.withLock { _meta.status = .exited }
    }

    func markDormant() {
        record("markDormant")
        lock.withLock { _meta.status = .exited }
    }

    func markDormant(reason: SessionSleepReason, audit: [String: String]) {
        markDormant()
    }

    func setTitle(_ title: String) {
        let changed = lock.withLock { () -> SessionMeta? in
            guard _meta.title != title else { return nil }
            _meta.title = title
            return _meta
        }
        if let changed { emitMeta(changed) }
    }

    func setArchived(_ archived: Bool) {
        let changed = lock.withLock { () -> SessionMeta? in
            guard _meta.archived != archived else { return nil }
            _meta.archived = archived
            return _meta
        }
        if let changed { emitMeta(changed) }
    }

    @discardableResult
    func onExit(_ listener: @escaping ExitListener) -> Cancel {
        subscribe(.exit) { exitListeners[$0] = listener }
    }

    @discardableResult
    func onActivity(_ listener: @escaping ActivityListener) -> Cancel {
        subscribe(.activity) { activityListeners[$0] = listener }
    }

    @discardableResult
    func onMetaChange(_ listener: @escaping MetaChangeListener) -> Cancel {
        subscribe(.meta) { metaListeners[$0] = listener }
    }

    // MARK: internals

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    private func emitGrid(owner: String?, cols: Int, rows: Int) {
        for l in lock.withLock({ Array(gridListeners.values) }) { l(owner, cols, rows) }
    }

    private func emitMeta(_ meta: SessionMeta) {
        for l in lock.withLock({ Array(metaListeners.values) }) { l(meta) }
    }

    private enum Listener { case output, activity, exit, grid, meta }

    private func subscribe(_ kind: Listener, _ install: (Int) -> Void) -> Cancel {
        let token = lock.withLock { () -> Int in
            let t = nextToken
            nextToken += 1
            install(t)
            return t
        }
        return { [weak self] in self?.detach(kind, token) }
    }

    private func detach(_ kind: Listener, _ token: Int) {
        lock.withLock {
            switch kind {
            case .output: outputListeners[token] = nil
            case .activity: activityListeners[token] = nil
            case .exit: exitListeners[token] = nil
            case .grid: gridListeners[token] = nil
            case .meta: metaListeners[token] = nil
            }
        }
    }
}

// MARK: - Recorders

/// Collects bytes handed to a (non-main-actor) output listener.
private final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ bytes: [UInt8]) {
        lock.withLock { seen.append(String(decoding: bytes, as: UTF8.self)) }
    }

    func texts() -> [String] { lock.withLock { seen } }
}

/// Collects grid changes as `owner:colsxrows`.
private final class GridRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ owner: String?, _ cols: Int, _ rows: Int) {
        lock.withLock { seen.append("\(owner ?? "nil"):\(cols)x\(rows)") }
    }

    func changes() -> [String] { lock.withLock { seen } }
}

/// Collects arbitrary labelled events in order.
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ event: String) { lock.withLock { seen.append(event) } }

    func events() -> [String] { lock.withLock { seen } }
}
