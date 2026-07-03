import XCTest
@testable import JuancodeServices

/// `PortKiller.parseListeners` turns `lsof -Fpc` field output into deduped processes.
final class PortKillerTests: XCTestCase {
    func testParsesPidAndCommand() {
        let out = "p12345\ncnode\n"
        let procs = PortKiller.parseListeners(lsofFieldOutput: out)
        XCTAssertEqual(procs, [PortProcess(pid: 12345, command: "node")])
    }

    func testEmptyOutputIsFreePort() {
        XCTAssertEqual(PortKiller.parseListeners(lsofFieldOutput: ""), [])
    }

    func testMultipleProcessesAndDedup() {
        // lsof repeats the p record per open file; the same pid must collapse to one.
        let out = """
        p100
        cnode
        p100
        cnode
        p200
        cpython3
        """
        let procs = PortKiller.parseListeners(lsofFieldOutput: out)
        XCTAssertEqual(procs, [
            PortProcess(pid: 100, command: "node"),
            PortProcess(pid: 200, command: "python3"),
        ])
    }

    func testIgnoresUnknownFieldLines() {
        // Extra field lines (e.g. from a broader -F set) must not break parsing.
        let out = "p777\ncvite\nn*:5173\nPTCP\n"
        let procs = PortKiller.parseListeners(lsofFieldOutput: out)
        XCTAssertEqual(procs, [PortProcess(pid: 777, command: "vite")])
    }

    func testPidWithoutCommandStillCounts() {
        let out = "p42\n"
        XCTAssertEqual(PortKiller.parseListeners(lsofFieldOutput: out),
                       [PortProcess(pid: 42, command: "")])
    }
}
