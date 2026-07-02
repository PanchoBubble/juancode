import Testing
@testable import JuancodeCore

/// Mirrors apps/server/src/providers.test.ts.
@Suite struct ProvidersTests {
    let id = "11111111-1111-1111-1111-111111111111"
    let sid = "abc-123"

    @Test func startArgsNoAcceptAllByDefault() {
        #expect(Providers.claude.startArgs(id, SpawnOptions()) == ["--session-id", id])
        #expect(Providers.codex.startArgs(id, SpawnOptions()) == [])
    }

    @Test func startArgsActivatesAcceptAllFlag() {
        #expect(Providers.claude.startArgs(id, SpawnOptions(skipPermissions: true))
            == ["--session-id", id, "--dangerously-skip-permissions"])
        #expect(Providers.codex.startArgs(id, SpawnOptions(skipPermissions: true))
            == ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test func resumeArgsNoAcceptAllByDefault() {
        #expect(Providers.claude.resumeArgs(sid, SpawnOptions()) == ["--resume", sid])
        #expect(Providers.codex.resumeArgs(sid, SpawnOptions()) == ["resume", sid])
    }

    @Test func resumeArgsActivatesAcceptAllFlag() {
        #expect(Providers.claude.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["--resume", sid, "--dangerously-skip-permissions"])
        #expect(Providers.codex.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["resume", "--dangerously-bypass-approvals-and-sandbox", sid])
    }

    @Test func startArgsPinsModelWhenSet() {
        // Claude: --model trails the session-id (and accept-all, when present).
        #expect(Providers.claude.startArgs(id, SpawnOptions(model: "opus"))
            == ["--session-id", id, "--model", "opus"])
        #expect(Providers.claude.startArgs(id, SpawnOptions(skipPermissions: true, model: "opus"))
            == ["--session-id", id, "--dangerously-skip-permissions", "--model", "opus"])
        // Codex takes the same --model flag (shared SpawnOptions codepath).
        #expect(Providers.codex.startArgs(id, SpawnOptions(model: "gpt-5"))
            == ["--model", "gpt-5"])
        #expect(Providers.codex.startArgs(id, SpawnOptions(skipPermissions: true, model: "gpt-5"))
            == ["--dangerously-bypass-approvals-and-sandbox", "--model", "gpt-5"])
    }

    @Test func resumeArgsPinsModelWhenSet() {
        #expect(Providers.claude.resumeArgs(sid, SpawnOptions(model: "opus"))
            == ["--resume", sid, "--model", "opus"])
        // Codex: --model must precede the session id (it's the positional resume arg).
        #expect(Providers.codex.resumeArgs(sid, SpawnOptions(model: "gpt-5"))
            == ["resume", "--model", "gpt-5", sid])
    }

    @Test func emptyModelAddsNoFlag() {
        // An empty string is treated as "unpinned" — no dangling --model with no value.
        #expect(Providers.claude.startArgs(id, SpawnOptions(model: "")) == ["--session-id", id])
        #expect(Providers.codex.startArgs(id, SpawnOptions(model: "")) == [])
    }

    @Test func pinsSessionIdFlags() {
        #expect(Providers.claude.pinsSessionId == true)
        #expect(Providers.codex.pinsSessionId == false)
    }
}
