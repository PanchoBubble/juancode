import XCTest
import JuancodeCore
@testable import JuancodeServices

/// The grid a viewport-less revive boots at. A resumed CLI reprints its transcript
/// at the boot grid and that reprint is wrapped for THAT size forever, so booting an
/// Oracle at the main panes' size (or at a hardcoded default) left the drawer narrow
/// and short until a deep refresh.
final class ResumeGridTests: XCTestCase {
    private let suite = "juancode-resume-grid-tests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        unsetenv("JUANCODE_ORACLE_DIR")
    }

    private func meta(cwd: String) -> SessionMeta {
        SessionMeta(id: "s1", provider: .claude, cwd: cwd, title: "t", status: .exited,
                    exitCode: 0, createdAt: nowMs(), updatedAt: nowMs(),
                    cliSessionId: "conv-1", skipPermissions: false,
                    worktreePath: nil, usage: nil)
    }

    func testOracleSessionResumesAtTheDockGrid() {
        setenv("JUANCODE_ORACLE_DIR", "/tmp/oracle-ctl", 1)
        OracleDockGrid.remember(cols: 152, rows: 80, in: defaults)
        let g = resumeGrid(for: meta(cwd: "/tmp/oracle-ctl"), defaults: defaults)
        XCTAssertEqual(g.cols, 152)
        XCTAssertEqual(g.rows, 80)
    }

    func testProjectSessionResumesAtTheMainPaneGrid() {
        setenv("JUANCODE_ORACLE_DIR", "/tmp/oracle-ctl", 1)
        OracleDockGrid.remember(cols: 152, rows: 80, in: defaults)
        let g = resumeGrid(for: meta(cwd: "/tmp/project"), defaults: defaults)
        XCTAssertEqual(g.cols, TerminalGrid.spawn.cols)
        XCTAssertEqual(g.rows, TerminalGrid.spawn.rows)
    }

    /// Before any dock surface has measured a grid there's nothing Oracle-specific
    /// to use, so an Oracle falls back to the main panes' size rather than a guess.
    func testOracleFallsBackToTheMainPaneGridBeforeTheDockHasMeasured() {
        setenv("JUANCODE_ORACLE_DIR", "/tmp/oracle-ctl", 1)
        let g = resumeGrid(for: meta(cwd: "/tmp/oracle-ctl"), defaults: defaults)
        XCTAssertEqual(g.cols, TerminalGrid.spawn.cols)
        XCTAssertEqual(g.rows, TerminalGrid.spawn.rows)
    }

    /// A collapsing drawer / mid-animation frame isn't a grid anyone reads.
    func testTooSmallAGridIsNotRemembered() {
        OracleDockGrid.remember(cols: 4, rows: 2, in: defaults)
        XCTAssertNil(OracleDockGrid.stored(in: defaults))
    }
}
