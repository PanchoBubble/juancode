import Foundation
import Testing

@testable import JuancodeCore

/// Refusing to spawn a provider whose CLI isn't installed (juancode-meqj): the caller
/// gets a named error instead of a session whose child died in `execvp`, and the
/// permissive path (a resolver that does find something) is untouched.
@Suite struct MissingCliSpawnTests {
    /// Resolves nothing — what `DefaultBinaryResolver` reports when every probe misses.
    struct MissingResolver: BinaryResolver {
        func command(for provider: ProviderId) -> String { "not-installed-cli" }
        func resolved(for provider: ProviderId) -> String? { nil }
    }

    /// A resolver that only implements `command` — the shape every existing test fake
    /// uses — must keep working through the protocol's default `resolved`.
    struct LegacyResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// Records the durable lifecycle events a session logs.
    final class EventLog: SessionActivityLogging, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func log(_ event: String, sessionId: String, project: String, fields: [String: String]) {
            lock.withLock { events.append(event) }
        }
        var all: [String] { lock.withLock { events } }
    }

    private var cwd: String { FileManager.default.temporaryDirectory.path }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func creatingASessionForAnUninstalledCliThrowsInsteadOfSpawning() throws {
        let log = EventLog()
        let env = SessionEnvironment(
            resolver: MissingResolver(),
            discoverCliSessionId: { _, _, _ in nil },
            log: log)

        #expect(throws: SessionError.self) {
            _ = try Session.create(provider: .opencode, cwd: cwd, cols: 80, rows: 24, env: env)
        }
        // Logged for the record, and never counted as a spawn.
        #expect(log.all.contains("cliNotFound"))
        #expect(!log.all.contains("spawn"))
    }

    @Test func theErrorNamesTheProviderAndItsOverride() {
        let env = SessionEnvironment(
            resolver: MissingResolver(), discoverCliSessionId: { _, _, _ in nil })
        do {
            _ = try Session.create(provider: .codex, cwd: cwd, cols: 80, rows: 24, env: env)
            Issue.record("expected the spawn to be refused")
        } catch let error {
            let text = "\(error)"
            #expect(text.contains("Codex"))
            #expect(text.contains("not-installed-cli"))
        }
    }

    @Test func aResolverThatFindsTheBinaryStillSpawns() throws {
        let env = SessionEnvironment(
            resolver: LegacyResolver(path: makeScript("cat\n")),
            discoverCliSessionId: { _, _, _ in nil })
        let session = try Session.create(provider: .claude, cwd: cwd, cols: 80, rows: 24, env: env)
        defer { session.kill() }
        #expect(session.meta.status == .running)
    }
}
