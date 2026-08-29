import Foundation

/// A named capability from the `serverInfo` handshake, as the UI needs to reason
/// about it: what it is called on the wire, what part of the app it powers, and
/// what the app does instead when the connected core does not advertise it.
///
/// The point of the enum is that "this core cannot do X" has exactly one spelling.
/// A gated affordance reads its reason from here, so a greyed-out button and the
/// Settings capability list can never disagree, and neither can drift from the
/// capability string the core actually sent.
public enum CoreCapability: String, Sendable, CaseIterable {
    case queue
    case trackedPrs
    case editor
    case terminal
    case adoptExternal
    case inputAck
    case resizeAck
    case screen
    case sessionMeta
    case gridOwner
    case restartFresh
    case spawnModel
    case isolateWorktree

    /// What the user calls this.
    public var title: String {
        switch self {
        case .queue: return "Message queue"
        case .trackedPrs: return "Tracked PRs"
        case .editor: return "Editor sessions"
        case .terminal: return "Terminal panel"
        case .adoptExternal: return "Adopt external session"
        case .inputAck: return "Input acks"
        case .resizeAck: return "Resize acks"
        case .screen: return "Rendered-screen stream"
        case .sessionMeta: return "Live meta updates"
        case .gridOwner: return "Grid ownership"
        case .restartFresh: return "Restart as a fresh conversation"
        case .spawnModel: return "Pinned model"
        case .isolateWorktree: return "Isolate in a fresh worktree"
        }
    }

    /// What the app does instead on a core that lacks it. Written as the sentence
    /// the UI shows, so it names the consequence rather than the missing frame.
    public var degradation: String {
        switch self {
        case .queue:
            return "Send-to-agent and review feedback are unavailable: nothing holds a message until the agent is idle, so the action is disabled rather than pasted mid-turn."
        case .trackedPrs:
            return "PRs cannot be tracked: Track and Track & send are disabled, and the tracked-PR list stays empty."
        case .editor:
            return "Open-in-editor is unavailable: no editor pty can be opened for a session."
        case .terminal:
            return "The bottom terminal panel is unavailable: no shell pty can be opened."
        case .adoptExternal:
            return "An existing CLI conversation started outside juancode cannot be adopted."
        case .inputAck:
            return "Keystrokes are sent unacknowledged, so a dropped write is not retried."
        case .resizeAck:
            return "A resize is not confirmed, so a grid that never reached the pty is not re-asserted."
        case .screen:
            return "Panes seed from raw scrollback replay instead of the core's parsed screen."
        case .sessionMeta:
            return "A session row is frozen at the meta it was created or attached with: a title the CLI derives for itself, or an edit made elsewhere, does not surface until relaunch."
        case .gridOwner:
            return "The app cannot tell who holds a session's pty grid, so a pane cannot render itself read-only when another client is driving."
        case .restartFresh:
            return "An exited session with nothing to resume cannot be restarted in place: it stays a replay-only pane, and starting over means a new session with a new id."
        case .spawnModel:
            return "The model pin is dropped: every session, including a dispatched one that asked for a specific model, runs on the CLI's own default."
        case .isolateWorktree:
            return "A session cannot be given a worktree of its own: the isolate toggle is disabled, and a dispatch that asks for isolation is refused rather than run in the shared checkout."
        }
    }
}

/// Raised when the app asks a core for something its capability list does not
/// cover. Thrown rather than silently no-oped: a caller that reached a gated
/// operation anyway is a UI bug, and a thrown error surfaces it.
public struct CoreCapabilityError: LocalizedError {
    public let capability: CoreCapability
    public let backend: String

    public init(_ capability: CoreCapability, backend: String) {
        self.capability = capability
        self.backend = backend
    }

    public var errorDescription: String? {
        "\(capability.title) is not available on the \(backend) core. \(capability.degradation)"
    }
}

/// Raised for an operation no core-to-core wire frame exists for at all, so it is
/// not a capability a core could advertise its way out of.
public struct CoreOperationUnsupported: LocalizedError {
    public let operation: String
    public let backend: String
    public let detail: String

    public init(operation: String, backend: String, detail: String) {
        self.operation = operation
        self.backend = backend
        self.detail = detail
    }

    public var errorDescription: String? {
        "\(operation) is not supported by the \(backend) core: \(detail)"
    }
}

public extension CoreClient {
    /// Whether the connected core advertises `capability`.
    func supports(_ capability: CoreCapability) -> Bool { info.has(capability.rawValue) }

    /// Every capability the app knows about that this core does not advertise, in
    /// declaration order, for the Settings list and for bug reports.
    var missingCapabilities: [CoreCapability] {
        CoreCapability.allCases.filter { !supports($0) }
    }

    /// The reason to show on a disabled affordance, or nil when the capability is
    /// there and the affordance should behave normally.
    func unavailableReason(_ capability: CoreCapability) -> String? {
        supports(capability) ? nil : capability.degradation
    }
}
