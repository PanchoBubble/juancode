import Foundation
import Testing
@testable import JuancodeCore

@Suite struct SessionCreationOrderTests {
    @Test func mixedProvidersKeepCreationOrderWhenStatusAndRecencyChange() {
        func session(_ id: String, _ provider: ProviderId, _ createdAt: Int) -> SessionMeta {
            SessionMeta(id: id, provider: provider, cwd: "/project", title: id,
                        status: .running, exitCode: nil, createdAt: createdAt,
                        updatedAt: createdAt, cliSessionId: nil, skipPermissions: false,
                        worktreePath: nil, usage: nil)
        }
        var metas = [session("claude", .claude, 100), session("codex", .codex, 300),
                     session("opencode", .opencode, 200), session("tie", .claude, 300)]
        let expected = ["codex", "tie", "opencode", "claude"]
        #expect(metas.sorted(by: sessionCreationPrecedes).map(\.id) == expected)
        metas[0].updatedAt = 999
        metas[1].status = .exited
        metas[1].dormant = true
        #expect(metas.reversed().sorted(by: sessionCreationPrecedes).map(\.id) == expected)
    }
}
