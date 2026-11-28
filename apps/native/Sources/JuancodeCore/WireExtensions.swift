import Foundation
// Re-exported so every `import JuancodeCore` keeps seeing the wire types (juancode-3aq8.2).
@_exported import JuancodeWire

extension SessionUsage {
    public var contextPressure: ContextPressure { contextPressure() }

    /// `contextPressure` against a handoff line other than the default (the setting).
    public func contextPressure(
        handoffTokens: Int = ContextPressure.defaultHandoffTokens) -> ContextPressure {
        ContextPressure.of(fraction: contextFraction, tokens: contextTokens,
                           handoffTokens: handoffTokens)
    }
}

extension SessionMeta {
    /// Build a persisted session that *adopts* an existing external CLI conversation
    /// (juancode-iqi): a fresh juancode `id` pointing at an already-known
    /// `cliSessionId` that ran in `cwd`. `startMs` (when the conversation began)
    /// becomes `createdAt` so the adopted row sorts by its real age. The title is a
    /// placeholder mirroring `Session.create`; the live session's poll loop derives
    /// the real title + usage from the transcript once it's resumed.
    public static func adopting(
        provider: ProviderId,
        cliSessionId: String,
        cwd: String,
        startMs: Int,
        skipPermissions: Bool = true
    ) -> SessionMeta {
        let spec = Providers.spec(for: provider)
        let folder = (cwd as NSString).lastPathComponent
        return SessionMeta(
            id: UUID().uuidString.lowercased(),
            provider: provider,
            cwd: cwd,
            title: "\(spec.label) · \(folder.isEmpty ? cwd : folder)",
            status: .running,
            exitCode: nil,
            createdAt: startMs,
            updatedAt: nowMs(),
            cliSessionId: cliSessionId,
            skipPermissions: skipPermissions,
            worktreePath: nil,
            usage: nil
        )
    }
}
