import XCTest
@testable import JuancodeCore

final class LaunchArchiveOverflowTests: XCTestCase {
    private func meta(_ id: String, cwd: String = "/p", updatedAt: Int,
                      archived: Bool = false) -> SessionMeta {
        var m = SessionMeta(
            id: id, provider: .claude, cwd: cwd, title: id,
            status: .exited, exitCode: 0, createdAt: 0, updatedAt: updatedAt,
            cliSessionId: nil, skipPermissions: false, worktreePath: nil,
            usage: nil)
        m.archived = archived
        return m
    }

    private func overflow(_ metas: [SessionMeta], protected: Set<String> = []) -> [String] {
        launchArchiveOverflow(metas, keep: 2, projectKey: { $0 }, protected: protected)
    }

    func testOldestPastTheCapAreArchived() {
        let metas = [meta("a", updatedAt: 1), meta("b", updatedAt: 3),
                     meta("c", updatedAt: 2), meta("d", updatedAt: 4)]
        XCTAssertEqual(overflow(metas), ["c", "a"])
    }

    func testCapIsPerProject() {
        let metas = [meta("a", cwd: "/p", updatedAt: 1), meta("b", cwd: "/p", updatedAt: 2),
                     meta("c", cwd: "/q", updatedAt: 3), meta("d", cwd: "/q", updatedAt: 4)]
        XCTAssertEqual(overflow(metas), [])
    }

    func testProtectedAndArchivedNeitherCountNorGetArchived() {
        let metas = [meta("pinned", updatedAt: 9), meta("old", updatedAt: 1, archived: true),
                     meta("a", updatedAt: 5), meta("b", updatedAt: 4), meta("c", updatedAt: 3)]
        XCTAssertEqual(overflow(metas, protected: ["pinned"]), ["c"])
    }

    func testNonPositiveKeepDisablesTheTrim() {
        let metas = [meta("a", updatedAt: 1), meta("b", updatedAt: 2)]
        XCTAssertEqual(launchArchiveOverflow(metas, keep: 0, projectKey: { $0 }, protected: []), [])
    }
}
