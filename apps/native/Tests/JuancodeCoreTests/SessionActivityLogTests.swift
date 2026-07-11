import Foundation
import Testing
@testable import JuancodeCore

/// The rolling JSONL session activity log: append format, aggressive field
/// clipping, size-based rotation into a single `.1` sibling, and serialized
/// concurrent appends. Plus the wiring: a real session lifecycle (fake resolver +
/// real pty, as `SessionResumeSeedTests`) emits the expected event names through
/// the injected `SessionActivityLogging`, and the default env stays a no-op.
@Suite struct SessionActivityLogTests {
    private func makeDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-log-test-\(UUID().uuidString)").path
        return dir
    }

    private func lines(_ log: SessionActivityLog) -> [String] {
        log.flush()
        guard let text = try? String(contentsOfFile: log.logPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func parsed(_ line: String) -> [String: String]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
    }

    @Test func appendWritesOneJsonObjectPerLineWithCoreKeys() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let log = SessionActivityLog(directory: dir, now: { fixed })

        log.log("spawn", sessionId: "s-1", project: "/tmp/proj", fields: ["mode": "create"])
        log.log("exit", sessionId: "s-1", project: "/tmp/proj", fields: ["code": "0"])

        let all = lines(log)
        #expect(all.count == 2)
        let first = try #require(parsed(all[0]))
        #expect(first["event"] == "spawn")
        #expect(first["session"] == "s-1")
        #expect(first["project"] == "/tmp/proj")
        #expect(first["mode"] == "create")
        #expect(first["ts"]?.hasPrefix("2023-11-14T") == true)
        let second = try #require(parsed(all[1]))
        #expect(second["event"] == "exit")
        #expect(second["code"] == "0")
    }

    @Test func fieldValuesAreClippedHard() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = SessionActivityLog(directory: dir)

        let long = String(repeating: "x", count: 500)
        log.log("seedResult", sessionId: "s", project: "/p", fields: ["reason": long])

        let entry = try #require(parsed(lines(log)[0]))
        let reason = try #require(entry["reason"])
        // Clipped to the cap plus the ellipsis marker — never the full text.
        #expect(reason.count == SessionActivityLog.maxFieldChars + 1)
        #expect(reason.hasSuffix("…"))
    }

    @Test func rotatesAtCapIntoSingleSibling() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Tiny cap so a handful of ~120-byte lines forces multiple rotations.
        let log = SessionActivityLog(directory: dir, maxBytes: 400)

        for i in 0..<20 {
            log.log("activity", sessionId: "s-\(i)", project: "/p", fields: ["state": "busy"])
        }
        log.flush()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: log.logPath))
        #expect(fm.fileExists(atPath: log.logPath + ".1"))
        #expect(!fm.fileExists(atPath: log.logPath + ".2"))
        // Both files respect the cap (the active one may be mid-fill).
        func size(_ path: String) -> Int {
            ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        #expect(size(log.logPath) <= 400)
        #expect(size(log.logPath + ".1") <= 400)
        // Every surviving line is still whole, valid JSON — rotation never splits one.
        for line in lines(log) { #expect(parsed(line) != nil) }
    }

    @Test func concurrentAppendsSerializeIntoWholeLines() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = SessionActivityLog(directory: dir)

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<25 {
                        log.log("activity", sessionId: "task-\(t)", project: "/p",
                                fields: ["i": "\(i)"])
                    }
                }
            }
        }

        let all = lines(log)
        #expect(all.count == 200)
        for line in all { #expect(parsed(line) != nil) }
    }

    @Test func defaultEnvironmentLoggerIsNoop() {
        // The bare env must not write anywhere — tests and headless uses stay quiet.
        #expect(SessionEnvironment().log is NoopSessionActivityLog)
    }
}

/// In-memory `SessionActivityLogging` recorder for wiring assertions.
private final class RecordingLog: SessionActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(event: String, sessionId: String, project: String, fields: [String: String])] = []

    var events: [(event: String, sessionId: String, project: String, fields: [String: String])] {
        lock.withLock { _events }
    }
    var names: [String] { events.map(\.event) }

    func log(_ event: String, sessionId: String, project: String, fields: [String: String]) {
        lock.withLock { _events.append((event, sessionId, project, fields)) }
    }
}

/// Integration: a real pty lifecycle writes the expected event names through the
/// env-injected logger.
@Suite struct SessionActivityLogWiringTests {
    struct FakeResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    private func makeScript(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juancode-test-\(UUID().uuidString).sh")
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func poll(_ timeout: TimeInterval = 5.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func lifecycleEmitsSpawnActivityKillAndExit() async throws {
        let recorder = RecordingLog()
        let env = SessionEnvironment(
            resolver: FakeResolver(path: makeScript("printf 'working... esc to interrupt\\n'\ncat\n")),
            store: InMemorySessionStore(),
            discoverCodexId: { _, _ in nil },
            log: recorder
        )
        let cwd = FileManager.default.temporaryDirectory.path
        let s = try Session.create(provider: .claude, cwd: cwd, cols: 80, rows: 24, env: env)

        // The footer drives busy; its erasure never comes (cat), so the watchdog
        // isn't awaited — busy alone proves activity transitions are logged.
        await poll { recorder.names.contains("activity") }
        s.kill()
        await poll { recorder.names.contains("exit") }

        let names = recorder.names
        #expect(names.first == "spawn")
        #expect(names.contains("activity"))
        #expect(names.contains("kill"))
        #expect(names.contains("exit"))
        let spawn = try #require(recorder.events.first)
        #expect(spawn.sessionId == s.id)
        #expect(spawn.project == cwd)
        #expect(spawn.fields["mode"] == "create")
    }
}
