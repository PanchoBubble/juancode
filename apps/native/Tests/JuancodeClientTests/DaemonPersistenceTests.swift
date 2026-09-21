// Whether the sessions on screen survive quitting the app, and whether the app can
// say so.
//
// Two of the daemon's lifetime states outlive an app quit — the LaunchAgent's and one
// started with JUANCODE_DAEMON_PERSIST=1 — and on the wire both report `ownerState:
// unowned`, because neither has a launch to name. That is also what a daemon nobody
// got round to claiming reports. One of those three is a decision and two of them are
// accidents, and the difference is `ownerManaged`, which is what these tests are about.

import XCTest
@testable import JuancodeClient

final class DaemonPersistenceTests: XCTestCase {
    /// The whole point of the field: `unowned` is where a stated mode and an accident
    /// look identical, so the mode has to arrive as its own answer.
    func testAnUnownedDaemonIsOnlyPersistentWhenSomethingSaidSo() throws {
        let accident = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 17_640, "ownerState": "unowned", "ownerGraceMs": 120_000,
        ]))
        XCTAssertNil(accident.owner.managed)
        XCTAssertFalse(accident.owner.outlivesTheApp,
                       "an undeclared daemon does outlive the app, and promising that it "
                           + "will is the claim this field exists to withhold")
        XCTAssertNil(accident.persistence)

        let declared = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 17_640, "ownerState": "unowned", "ownerGraceMs": 0,
            "ownerManaged": "persistent", "buildId": "abc123-99",
        ]))
        XCTAssertEqual(declared.owner.managed, .persistent)
        XCTAssertTrue(declared.owner.outlivesTheApp)
        XCTAssertFalse(declared.owner.willBeReaped)
        XCTAssertTrue(declared.summary.contains("PERSISTENT"), declared.summary)
    }

    /// launchd's is the other stated mode and reads the same way, so the app has one
    /// answer for "do these sessions survive" rather than two spellings of it.
    func testLaunchdIsTheOtherStatedMode() throws {
        let managed = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 1_098, "ownerState": "unowned", "ownerGraceMs": 0,
            "ownerManaged": "launchd", "buildId": "def456-1",
        ]))
        XCTAssertEqual(managed.owner.managed, .launchd)
        XCTAssertTrue(managed.owner.outlivesTheApp)
        let note = try XCTUnwrap(managed.persistence)
        XCTAssertTrue(note.contains("launchd"), note)
        XCTAssertTrue(note.contains("def456-1"), "the build has to ride along: \(note)")
    }

    /// Choosing session persistence and knowing which code those sessions are running
    /// on is one glance, so the build is in the same sentence — including when there
    /// is no build to name, which is the answer that matters most.
    func testThePersistenceLineAlwaysSaysWhichBuildTheSessionsAreOn() throws {
        let stamped = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 42, "ownerState": "unowned", "ownerManaged": "persistent",
            "buildId": "9f3a21c-1789719151",
        ]))
        XCTAssertTrue(try XCTUnwrap(stamped.persistence).contains("9f3a21c-1789719151"))

        // Started outside the launch path, so there is no build id at all. Saying
        // nothing here would leave "sessions survive a quit" sounding like an
        // all-clear on a daemon whose code nobody can match to the checkout.
        let unstamped = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 43, "ownerState": "unowned", "ownerManaged": "persistent",
        ]))
        XCTAssertTrue(try XCTUnwrap(unstamped.persistence).contains("UNSTAMPED"))
    }

    /// The mode must not make a stale core quieter. A persistent daemon on an old
    /// build is still stale, still warned about, and still turns the badge yellow.
    func testAStatedModeNeverSilencesStaleness() throws {
        let daemon = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 44, "ownerState": "unowned", "ownerManaged": "persistent",
            "buildId": "old-1",
        ]))
        let app = AppIdentity(buildId: "new-2", sessionsPerProject: nil)
        let warnings = daemon.warnings(against: app, binaryModifiedAt: nil)
        XCTAssertEqual(warnings.first?.kind, .staleBuild)
        XCTAssertNotNil(daemon.persistence, "and it is still persistent while it is stale")
    }

    /// A daemon predating the field is unknown, not undeclared-and-therefore-fine.
    /// Same rule the three ownership states already follow.
    func testAnOlderDaemonReportsNoModeRatherThanTheWrongOne() throws {
        let silent = try XCTUnwrap(DaemonIdentity(json: ["pid": 9, "ownerState": "owned",
                                                         "ownerPid": 11]))
        XCTAssertNil(silent.owner.managed)
        XCTAssertNil(silent.persistence)
        XCTAssertTrue(silent.summary.contains("owned by pid 11"), silent.summary)

        let nonsense = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 10, "ownerState": "unowned", "ownerManaged": "whatever-comes-next",
        ]))
        XCTAssertNil(nonsense.owner.managed, "an unknown mode is unknown, never persistent")
        XCTAssertNil(nonsense.persistence)
    }

    /// The selection is what the badge and the Settings pane both read, so the answer
    /// has to be reachable from there and must not be smuggled into the warning list.
    func testTheSelectionCarriesPersistenceSeparatelyFromStaleness() throws {
        let daemon = try XCTUnwrap(DaemonIdentity(json: [
            "pid": 45, "ownerState": "unowned", "ownerManaged": "persistent",
            "buildId": "same-1",
        ]))
        let selection = CoreSelection(
            databasePath: "/tmp/x.db", rustCoreURL: "http://127.0.0.1:4290",
            daemon: daemon,
            daemonWarnings: daemon.warnings(against: AppIdentity(buildId: "same-1",
                                                                 sessionsPerProject: nil),
                                            binaryModifiedAt: nil))
        XCTAssertNotNil(selection.sessionPersistence)
        XCTAssertFalse(selection.daemonIsStale,
                       "the mode must never be carried as a warning; that is what turns "
                           + "the badge yellow")
    }

    /// A daemon that says nothing about its own lifetime must not be reported as
    /// outliving the app: silence is not a promise.
    func testADaemonThatSaysNothingClaimsNoPersistence() {
        let selection = CoreSelection(databasePath: "/tmp/x.db",
                                      rustCoreURL: "http://127.0.0.1:4290")
        XCTAssertNil(selection.sessionPersistence)
    }
}
