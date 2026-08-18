import Foundation
import JuancodeCore

public extension SessionEnvironment {
    /// A fully production-wired session environment: the real login-shell binary
    /// resolver, the given persistent store, real post-spawn session-id discovery for
    /// the providers that need it (Codex's rollout files, opencode's database), and
    /// live title/usage polling backed by this target's transcript readers
    /// (`deriveSessionTitle` / `deriveSessionUsage`). The core can't depend on
    /// JuancodeServices, so these seams are injected here.
    static func live(
        store: SessionStore,
        messageQueue: MessageQueue = MessageQueue(),
        scrollbackLimit: Int = Config.scrollbackLimit,
        log: SessionActivityLogging = NoopSessionActivityLog()
    ) -> SessionEnvironment {
        SessionEnvironment(
            resolver: DefaultBinaryResolver(),
            store: store,
            messageQueue: messageQueue,
            scrollbackLimit: scrollbackLimit,
            discoverCliSessionId: { provider, cwd, sinceMs in
                switch provider {
                case .claude:
                    return nil  // pinned up front, nothing to discover
                case .codex:
                    return await CodexSessionDiscovery.capture(cwd: cwd, sinceMs: sinceMs)
                case .opencode:
                    return await OpencodeStore.capture(cwd: cwd, sinceMs: sinceMs)
                }
            },
            deriveTitle: { provider, id in await deriveSessionTitle(provider, id) },
            deriveUsage: { provider, id in await deriveSessionUsage(provider, id) },
            startActivityTail: { provider, getId, onBatch in
                // opencode's turns live in its database, not an append-only transcript,
                // so it gets its own tail over the same listener contract.
                if provider == .opencode {
                    let tail = OpencodeActivityTail(cliSessionId: getId, listener: onBatch)
                    tail.start()
                    return { tail.stop() }
                }
                let tail = TranscriptActivityTail(
                    provider: provider,
                    cliSessionId: getId,
                    listener: onBatch
                )
                tail.start()
                return { tail.stop() }
            },
            log: log
        )
    }
}
