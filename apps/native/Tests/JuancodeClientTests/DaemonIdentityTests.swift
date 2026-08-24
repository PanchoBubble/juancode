import XCTest
import JuancodeCore
import JuancodeServer
@testable import JuancodeClient

/// The staleness handshake: what the daemon says about itself, and what the app is
/// allowed to conclude from it.
///
/// The failure being tested for is not a crash. It is two hours of reading a session
/// list that looked authoritative while it mirrored a daemon started before the app
/// was, under an older build, with an environment nobody could see. So every test
/// here is about a warning being present or absent, and the absent cases matter as
/// much: a badge that says "stale" during normal adoption teaches people to ignore it.
final class DaemonIdentityTests: XCTestCase {

    private static let bootMs = 1_700_000_000_000
    private var boot: Date { Date(timeIntervalSince1970: TimeInterval(Self.bootMs) / 1000) }

    private func identity(startedAt: Int? = bootMs, buildStamp: Int? = bootMs,
                          buildId: String? = nil, retention: Int? = 40) -> DaemonIdentity {
        var body: [String: Any] = ["pid": 4242, "version": "0.1.0",
                                   "exePath": "/checkout/target/debug/juancoded",
                                   "dataDir": "/home/.juancode/rust-core"]
        body["startedAt"] = startedAt
        body["buildStamp"] = buildStamp
        body["buildId"] = buildId
        body["sessionsPerProject"] = retention
        return DaemonIdentity(json: body)!
    }

    // MARK: - Decoding

    func testDecodesTheHandshakeBlock() {
        let daemon = identity(buildId: "abc123", retention: 0)
        XCTAssertEqual(daemon.pid, 4242)
        XCTAssertEqual(daemon.startedAt, boot)
        XCTAssertEqual(daemon.buildStamp, boot)
        XCTAssertEqual(daemon.buildId, "abc123")
        XCTAssertEqual(daemon.exePath, "/checkout/target/debug/juancoded")
        XCTAssertEqual(daemon.sessionsPerProject, 0)
    }

    /// An in-process core sends nothing here, and a daemon too old to identify
    /// itself sends nothing either. Both must decode to nil rather than to a
    /// half-filled identity that would then compare as "matches".
    func testAbsentOrShapelessDaemonBlockIsNil() {
        XCTAssertNil(DaemonIdentity(json: nil))
        XCTAssertNil(DaemonIdentity(json: [:]))
        XCTAssertNil(DaemonIdentity(json: "juancoded"))
        // No pid is no identity: the pid is the only thing a reader can act on.
        XCTAssertNil(DaemonIdentity(json: ["version": "0.1.0"]))
    }

    /// A field the daemon could not read is unknown, never "matches". A daemon that
    /// cannot stat its own binary must not be able to pass the build comparison by
    /// omission.
    func testMissingFieldsDecodeToUnknownNotToAgreement() {
        let daemon = identity(startedAt: nil, buildStamp: nil, retention: nil)
        XCTAssertNil(daemon.startedAt)
        XCTAssertNil(daemon.buildStamp)
        XCTAssertNil(daemon.sessionsPerProject)
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: nil, sessionsPerProject: 40)
        XCTAssertEqual(daemon.warnings(against: app, binaryModifiedAt: boot), [])
    }

    // MARK: - The healthy case

    /// The daemon this launch just adopted: same build id, and the app started after
    /// it. Nothing is wrong, and nothing may be said — a daemon outliving the app is
    /// the design, not the bug.
    func testAnAdoptedMatchingDaemonProducesNoWarnings() {
        let daemon = identity(buildId: "abc123")
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "abc123", sessionsPerProject: 40)
        XCTAssertEqual(daemon.warnings(against: app, binaryModifiedAt: boot), [])
    }

    // MARK: - Stale build

    /// Juan's case, stated exactly: the daemon is running a build the checkout has
    /// moved past. The build ids differ, so no interpretation is needed.
    func testMismatchedBuildIdsAreStale() {
        let daemon = identity(buildId: "old111")
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "new222", sessionsPerProject: 40)
        let warnings = daemon.warnings(against: app, binaryModifiedAt: boot)
        XCTAssertEqual(warnings.map(\.kind), [.staleBuild])
        XCTAssertTrue(warnings[0].headline.contains("old111"), warnings[0].headline)
        XCTAssertTrue(warnings[0].detail.contains("--restart-daemon"), warnings[0].detail)
    }

    /// With nothing stamped — a daemon somebody started by hand — the binary's mtime
    /// is the fallback: rebuilt after the daemon booted means the daemon is old.
    func testARebuiltBinaryIsStaleEvenWithNoBuildStamp() {
        let daemon = identity()
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: nil, sessionsPerProject: 40)
        let rebuilt = boot.addingTimeInterval(1800)
        let warnings = daemon.warnings(against: app, binaryModifiedAt: rebuilt)
        // Not also `.predatesLaunch`: one restart fixes both, and two lines for one
        // remedy is how a warning starts getting scrolled past.
        XCTAssertEqual(warnings.map(\.kind), [.staleBuild])
        XCTAssertTrue(warnings[0].detail.contains("/checkout/target/debug/juancoded"),
                      warnings[0].detail)
    }

    /// The same binary, re-stat'ed, must not read as a rebuild. A one-second slack
    /// keeps filesystem timestamp granularity from inventing staleness on every boot.
    func testAnUnchangedBinaryIsNotAReuild() {
        let daemon = identity(buildId: "abc123")
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "abc123", sessionsPerProject: 40)
        XCTAssertEqual(daemon.warnings(against: app,
                                       binaryModifiedAt: boot.addingTimeInterval(0.5)), [])
    }

    // MARK: - Predates the launch

    /// A daemon older than this app launch is only worth flagging when this launch's
    /// environment provably did not reach it. Unstamped is unproven, so it is flagged.
    func testAnUnstampedOlderDaemonIsFlaggedAsPredatingTheLaunch() {
        let daemon = identity()
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(7200),
                              buildId: nil, sessionsPerProject: 40)
        let warnings = daemon.warnings(against: app, binaryModifiedAt: boot)
        XCTAssertEqual(warnings.map(\.kind), [.predatesLaunch])
        XCTAssertTrue(warnings[0].detail.contains("JUANCODE_*"), warnings[0].detail)
    }

    /// A daemon this launch started cannot predate it, and must say nothing.
    func testADaemonStartedAfterTheAppIsNotFlagged() {
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(-60),
                              buildId: nil, sessionsPerProject: 40)
        let daemon = identity()
        XCTAssertEqual(daemon.warnings(against: app, binaryModifiedAt: boot), [])
    }

    // MARK: - Retention

    /// The pruning half of the incident: 28 freshly imported sessions vanished
    /// because the daemon kept the cap of 40 it had booted with, while the app had
    /// been relaunched with the variable set. The app can now say so.
    func testARetentionThatTheDaemonNeverSawIsReported() {
        let daemon = identity(buildId: "abc123", retention: 40)
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "abc123", sessionsPerProject: 0)
        let warnings = daemon.warnings(against: app, binaryModifiedAt: boot)
        XCTAssertEqual(warnings.map(\.kind), [.retentionMismatch])
        XCTAssertTrue(warnings[0].headline.contains("40 sessions"), warnings[0].headline)
        XCTAssertTrue(warnings[0].headline.contains("unlimited"), warnings[0].headline)
    }

    /// Nothing set on this launch line means nothing to disagree about: the daemon's
    /// cap is simply the cap, and a warning would be noise.
    func testNoRetentionInTheAppsEnvironmentIsNotAMismatch() {
        let daemon = identity(buildId: "abc123", retention: 40)
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "abc123", sessionsPerProject: nil)
        XCTAssertEqual(daemon.warnings(against: app, binaryModifiedAt: boot), [])
    }

    // MARK: - Reaching the selection

    /// The badge and the Settings pane read `CoreSelection`, so that is where the
    /// verdict has to land — not in a log nobody opens.
    func testBootPutsTheVerdictOnTheSelection() {
        let daemon = identity(buildId: "old111")
        let app = AppIdentity(launchedAt: boot.addingTimeInterval(3600),
                              buildId: "new222", sessionsPerProject: 40)
        let booted = CoreBoot.boot(
            persisted: .rust, override: nil, rustCoreURL: "http://127.0.0.1:4290",
            makeSwift: { _ in (FakeCore(capabilities: []), nil) },
            makeRust: { _ in FakeCore(capabilities: ["inputAck"], daemon: daemon) },
            appIdentity: app)
        XCTAssertEqual(booted.selection.active, .rust)
        XCTAssertTrue(booted.selection.daemonIsStale)
        XCTAssertEqual(booted.selection.daemon?.pid, 4242)
        XCTAssertEqual(booted.selection.daemonWarnings.map(\.kind), [.staleBuild])
        // Staleness is never a fallback: the daemon owns live ptys, and refusing to
        // connect would end them to fix a reporting problem.
        XCTAssertNil(booted.selection.unreachableReason)
        XCTAssertFalse(booted.selection.didFallBack)
    }

    /// An in-process core has no daemon and can never be stale against itself.
    func testTheSwiftCoreIsNeverStale() {
        let booted = CoreBoot.boot(
            persisted: .swift, override: nil, rustCoreURL: "http://127.0.0.1:1",
            makeSwift: { _ in (FakeCore(capabilities: []), nil) },
            makeRust: { _ in FakeCore(capabilities: []) })
        XCTAssertNil(booted.selection.daemon)
        XCTAssertFalse(booted.selection.daemonIsStale)
    }

    /// The app's launch time comes from the kernel, not from a `Date()` captured
    /// somewhere during boot: the comparison it feeds is "did the daemon predate this
    /// launch", and a value that drifts by however long the app took to start is the
    /// wrong side of that question.
    func testProcessStartTimeIsRealAndInThePast() {
        let started = AppIdentity.processStartTime()
        XCTAssertNotNil(started)
        XCTAssertLessThanOrEqual(started!, Date())
        XCTAssertGreaterThan(started!, Date(timeIntervalSinceNow: -86_400))
    }
}
