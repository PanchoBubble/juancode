import Foundation
import Testing
@testable import JuancodeCore

/// The FSEvents worktree watcher: it must fire on a real filesystem change, filter
/// `.git/` noise down to HEAD/index, and share one stream per path across
/// subscribers (so N open worktrees cost N streams, not N×consumers).
@Suite struct WorktreeWatcherTests {
    /// Thread-safe fire counter for the watcher's background change callback.
    final class Fires: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private func poll(_ timeout: TimeInterval = 5.0, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - path filtering (pure)

    @Test func plainWorktreePathsAreRelevant() {
        #expect(WorktreeWatcher.isRelevantPath("/repo/src/main.swift", root: "/repo"))
        #expect(WorktreeWatcher.isRelevantPath("/repo/README.md", root: "/repo"))
    }

    @Test func gitInternalsAreIgnoredExceptHeadAndIndex() {
        #expect(!WorktreeWatcher.isRelevantPath("/repo/.git/objects/ab/cdef", root: "/repo"))
        #expect(!WorktreeWatcher.isRelevantPath("/repo/.git/logs/HEAD", root: "/repo"))
        #expect(!WorktreeWatcher.isRelevantPath("/repo/.git", root: "/repo")) // the .git dir
        #expect(WorktreeWatcher.isRelevantPath("/repo/.git/HEAD", root: "/repo"))
        #expect(WorktreeWatcher.isRelevantPath("/repo/.git/index", root: "/repo"))
    }

    @Test func theWatchedRootItselfIsNotRelevant() {
        // FSEvents reports every ancestor dir of a change, so a bare-root event is
        // noise — .git-only churn would otherwise always surface the root too.
        #expect(!WorktreeWatcher.isRelevantPath("/repo", root: "/repo"))
        #expect(!WorktreeWatcher.isRelevantPath("/repo/", root: "/repo"))
    }

    // MARK: - live watching

    @Test func firesWhenAFileIsCreated() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fires = Fires()
        let registry = WorktreeWatcherRegistry()
        let token = try #require(registry.watch(path: dir.path) { fires.bump() })
        defer { token.cancel() }

        // Let the stream come up before mutating (FSEvents ignores pre-start writes).
        try? await Task.sleep(nanoseconds: 300_000_000)
        try "hello".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        #expect(await poll { fires.count > 0 }, "watcher never fired on a file create")
    }

    @Test func gitObjectChurnDoesNotFire() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gitObjects = dir.appendingPathComponent(".git/objects/ab")
        try FileManager.default.createDirectory(at: gitObjects, withIntermediateDirectories: true)

        let fires = Fires()
        let registry = WorktreeWatcherRegistry()
        let token = try #require(registry.watch(path: dir.path) { fires.bump() })
        defer { token.cancel() }

        try? await Task.sleep(nanoseconds: 300_000_000)
        try "obj".write(to: gitObjects.appendingPathComponent("deadbeef"), atomically: true, encoding: .utf8)

        // Give the debounce window a beat; it must stay silent.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(fires.count == 0, "git object churn should be filtered out")
    }

    // MARK: - sharing / reference counting

    @Test func oneStreamSharedAcrossSubscribers() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = WorktreeWatcherRegistry()
        let a = try #require(registry.watch(path: dir.path) { })
        let b = try #require(registry.watch(path: dir.path) { })
        #expect(registry.activeStreamCount == 1)

        a.cancel()
        #expect(registry.activeStreamCount == 1) // b still holds it

        b.cancel()
        #expect(registry.activeStreamCount == 0) // last consumer gone → torn down
    }

    @Test func bothSubscribersAreNotified() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = Fires(), b = Fires()
        let registry = WorktreeWatcherRegistry()
        let ta = try #require(registry.watch(path: dir.path) { a.bump() })
        let tb = try #require(registry.watch(path: dir.path) { b.bump() })
        defer { ta.cancel(); tb.cancel() }

        try? await Task.sleep(nanoseconds: 300_000_000)
        try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        #expect(await poll { a.count > 0 && b.count > 0 }, "a shared stream must fan out to every subscriber")
    }
}
