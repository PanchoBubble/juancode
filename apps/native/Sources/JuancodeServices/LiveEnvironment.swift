import Foundation
import JuancodeCore

public extension SessionEnvironment {
    /// A fully production-wired session environment: the real login-shell binary
    /// resolver, the given persistent store, real Codex session-id discovery, and
    /// live title/usage polling backed by this target's transcript readers
    /// (`deriveSessionTitle` / `deriveSessionUsage`). The core can't depend on
    /// JuancodeServices, so these seams are injected here.
    static func live(
        store: SessionStore,
        messageQueue: MessageQueue = MessageQueue(),
        scrollbackLimit: Int = Config.scrollbackLimit
    ) -> SessionEnvironment {
        SessionEnvironment(
            resolver: DefaultBinaryResolver(),
            store: store,
            messageQueue: messageQueue,
            scrollbackLimit: scrollbackLimit,
            deriveTitle: { provider, id in await deriveSessionTitle(provider, id) },
            deriveUsage: { provider, id in await deriveSessionUsage(provider, id) }
        )
    }
}
