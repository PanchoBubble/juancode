import Foundation
import JuancodeCore

/// Disposition (measured at this tree, juancode-880y): juancode-3s4p, inside the
/// juancode-nqpm commit. `SessionEnvironment.live` has exactly one caller in the
/// repo — `JuancodeServer/AppState.swift:63` — and no test file of its own. Every
/// seam it injects already lives in `JuancodeCore`, so there is nothing here to
/// relocate: it is a wiring shim for the in-process Swift core and it dies with it.

public extension SessionEnvironment {
    /// A production-wired session environment for the Swift core: the real
    /// login-shell binary resolver, the given persistent store, real post-spawn
    /// session-id discovery for the providers that need it (Codex's rollout files,
    /// opencode's database), and live title polling backed by this target's
    /// transcript readers (`deriveSessionTitle`). The core can't depend on
    /// JuancodeServices, so these seams are injected here.
    ///
    /// Two seams are deliberately NOT injected any more. Token usage and structured
    /// transcript activity are served by the Rust core (`juancoded-core/src/usage.rs`,
    /// `juancoded-transcripts`), and the Swift core never advertised either over the
    /// wire — `usage`, `transcript` and `transcript-activity` are skipped in
    /// `parity/swift-status.json` because it does not claim the capability. Their
    /// Swift readers were the fork this leaves behind, so they are gone and the
    /// environment falls back to what it documents as the default: no usage, and
    /// screen-only busy/idle detection.
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
            log: log
        )
    }
}
