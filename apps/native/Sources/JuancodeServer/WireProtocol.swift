import Foundation
import JuancodeCore
import JuancodeServices

/// The WebSocket wire protocol: tagged unions whose discriminator is the `type`
/// field; every other field sits flat alongside it. Originally a faithful mirror
/// of the (since-deleted) Node server's `protocol.ts` — the shape is preserved so
/// pre-existing clients keep working unchanged.
///
/// The living TS mirror is the oracle sidecar's `apps/oracle-mcp/src/native-events.ts`;
/// keep the two in sync (field names, casing, tags).

// MARK: - Client → server

public enum ClientMessage: Sendable {
    case create(provider: String, cwd: String, cols: Int, rows: Int,
                initialInput: String?, skipPermissions: Bool?, isolateWorktree: Bool?)
    case attach(sessionId: String, cols: Int, rows: Int)
    case reactivate(sessionId: String, cols: Int, rows: Int)
    /// Adopt an external CLI conversation (one started in a plain terminal) by its
    /// own resumable id, persisting a juancode session row and resuming it live.
    case adoptExternal(provider: String, cliSessionId: String, cwd: String,
                       startMs: Int, cols: Int, rows: Int)
    case setSkipPermissions(sessionId: String, skipPermissions: Bool, cols: Int, rows: Int)
    /// A keystroke / paste for a pty. `seq` is an optional per-connection
    /// monotonic id (juancode-1u3): when present the server replies with a
    /// matching `inputAck` after writing, so the client can buffer unacked input
    /// and resend it on reconnect. Nil for older clients / fire-and-forget writes.
    case input(sessionId: String, data: String, seq: Int?)
    /// Resize a pty's grid. `seq` is an optional per-connection monotonic id
    /// (juancode-uz6): when present the server replies with a matching `resizeAck`
    /// reporting whether the grid reached a live pty, so the client can re-assert a
    /// resize dropped because the pty wasn't running yet. Nil for older clients.
    case resize(sessionId: String, cols: Int, rows: Int, seq: Int?)
    case kill(sessionId: String)
    // ── Per-session message queue (oracle-cj3 / juancode-r82) ────────────────────
    /// Watch a session's pending message queue: the server replies with the current
    /// `queue` snapshot and pushes an updated snapshot on every change.
    case subscribeQueue(sessionId: String)
    /// Stop watching a session's message queue.
    case unsubscribeQueue(sessionId: String)
    /// Queue a message to a session for delivery on its next idle. Persisted and
    /// flushed in order; delivered promptly if the session is idle right now.
    case queueMessage(sessionId: String, text: String)
    /// Cancel a still-pending queued message before it's delivered.
    case dequeueMessage(sessionId: String, messageId: String)
    // ── Rendered-screen stream (juancode-a2h.3) ──────────────────────────────────
    /// Opt into the live rendered-screen stream for a session — the cheap,
    /// phone-friendly alternative to the full xterm `output` byte stream. The
    /// server replies immediately with a full snapshot (`screen` with
    /// `reset: true`) and thereafter pushes only the rows that changed
    /// (`reset: false`), coalesced on an ~80ms tick. Read-only: a screen viewer
    /// never participates in grid ownership, so it cannot resize the pty.
    /// Connections that never send this get the byte stream exactly as before.
    case subscribeScreen(sessionId: String)
    /// Stop the live screen stream for a session (the client closed that view).
    case unsubscribeScreen(sessionId: String)
    case openEditor(cwd: String, file: String, cols: Int, rows: Int)
    case openTerminal(cwd: String, cols: Int, rows: Int, requestId: String)
    // ── Tracked-PR registry (juancode-bt2) — keep beside the PR server messages ──
    /// Subscribe to the tracked-PR registry; the server replies with the current
    /// `trackedPrs` snapshot and pushes further updates as they happen.
    case subscribeTrackedPrs
    /// Start tracking `pr` in `cwd` (spawns its driving agent session server-side).
    case trackPr(cwd: String, pr: PullRequest)
    /// Stop tracking the PR whose `TrackedPr.key` is `trackedId`.
    case untrackPr(trackedId: String)
    /// Dismiss a surfaced needs-decision notification.
    case resolveTrackNotification(trackedId: String, notificationId: String)
    /// A well-formed message whose `type` this server doesn't implement — e.g. a
    /// newer client feature, or a TS-only message the embedded server doesn't
    /// support (`subscribeStructured`, `steerMessage`, …). Decoding degrades to
    /// this instead of failing, so an unknown type is silently ignored rather than
    /// killing the message with a spurious "Invalid JSON" (juancode-tgc). Clients
    /// feature-detect via the `serverInfo` capabilities to avoid sending these.
    case unknown(type: String)
}

extension ClientMessage: Decodable {
    private enum K: String, CodingKey {
        case type, provider, cwd, cols, rows, initialInput, skipPermissions, isolateWorktree
        case sessionId, data, file, requestId, cliSessionId, startMs, seq
        // Tracked-PR registry (juancode-bt2).
        case pr, trackedId, notificationId
        // Per-session message queue (oracle-cj3 / juancode-r82).
        case text, messageId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "create":
            self = .create(
                provider: try c.decode(String.self, forKey: .provider),
                cwd: try c.decode(String.self, forKey: .cwd),
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                initialInput: try c.decodeIfPresent(String.self, forKey: .initialInput),
                skipPermissions: try c.decodeIfPresent(Bool.self, forKey: .skipPermissions),
                isolateWorktree: try c.decodeIfPresent(Bool.self, forKey: .isolateWorktree)
            )
        case "attach":
            self = .attach(sessionId: try c.decode(String.self, forKey: .sessionId),
                           cols: try c.decode(Int.self, forKey: .cols),
                           rows: try c.decode(Int.self, forKey: .rows))
        case "reactivate":
            self = .reactivate(sessionId: try c.decode(String.self, forKey: .sessionId),
                               cols: try c.decode(Int.self, forKey: .cols),
                               rows: try c.decode(Int.self, forKey: .rows))
        case "adoptExternal":
            self = .adoptExternal(provider: try c.decode(String.self, forKey: .provider),
                                  cliSessionId: try c.decode(String.self, forKey: .cliSessionId),
                                  cwd: try c.decode(String.self, forKey: .cwd),
                                  startMs: try c.decode(Int.self, forKey: .startMs),
                                  cols: try c.decode(Int.self, forKey: .cols),
                                  rows: try c.decode(Int.self, forKey: .rows))
        case "setSkipPermissions":
            self = .setSkipPermissions(sessionId: try c.decode(String.self, forKey: .sessionId),
                                       skipPermissions: try c.decode(Bool.self, forKey: .skipPermissions),
                                       cols: try c.decode(Int.self, forKey: .cols),
                                       rows: try c.decode(Int.self, forKey: .rows))
        case "input":
            self = .input(sessionId: try c.decode(String.self, forKey: .sessionId),
                          data: try c.decode(String.self, forKey: .data),
                          seq: try c.decodeIfPresent(Int.self, forKey: .seq))
        case "resize":
            self = .resize(sessionId: try c.decode(String.self, forKey: .sessionId),
                           cols: try c.decode(Int.self, forKey: .cols),
                           rows: try c.decode(Int.self, forKey: .rows),
                           seq: try c.decodeIfPresent(Int.self, forKey: .seq))
        case "kill":
            self = .kill(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "subscribeQueue":
            self = .subscribeQueue(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "unsubscribeQueue":
            self = .unsubscribeQueue(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "queueMessage":
            self = .queueMessage(sessionId: try c.decode(String.self, forKey: .sessionId),
                                 text: try c.decode(String.self, forKey: .text))
        case "dequeueMessage":
            self = .dequeueMessage(sessionId: try c.decode(String.self, forKey: .sessionId),
                                   messageId: try c.decode(String.self, forKey: .messageId))
        case "subscribeScreen":
            self = .subscribeScreen(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "unsubscribeScreen":
            self = .unsubscribeScreen(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "openEditor":
            self = .openEditor(cwd: try c.decode(String.self, forKey: .cwd),
                               file: try c.decode(String.self, forKey: .file),
                               cols: try c.decode(Int.self, forKey: .cols),
                               rows: try c.decode(Int.self, forKey: .rows))
        case "openTerminal":
            self = .openTerminal(cwd: try c.decode(String.self, forKey: .cwd),
                                 cols: try c.decode(Int.self, forKey: .cols),
                                 rows: try c.decode(Int.self, forKey: .rows),
                                 requestId: try c.decode(String.self, forKey: .requestId))
        case "subscribeTrackedPrs":
            self = .subscribeTrackedPrs
        case "trackPr":
            self = .trackPr(cwd: try c.decode(String.self, forKey: .cwd),
                            pr: try c.decode(PullRequest.self, forKey: .pr))
        case "untrackPr":
            self = .untrackPr(trackedId: try c.decode(String.self, forKey: .trackedId))
        case "resolveTrackNotification":
            self = .resolveTrackNotification(trackedId: try c.decode(String.self, forKey: .trackedId),
                                             notificationId: try c.decode(String.self, forKey: .notificationId))
        default:
            // Degrade gracefully: a well-formed frame with an unrecognised `type`
            // is tolerated (a newer/other-server feature), not a decode error. Only
            // genuinely malformed JSON still fails to decode (juancode-tgc).
            self = .unknown(type: type)
        }
    }
}

// MARK: - Server → client

/// Current wire-protocol version and the capabilities the embedded native server
/// implements (juancode-tgc). Mirrors `PROTOCOL_VERSION` / `ServerCapability` in the
/// two `protocol.ts` twins. The native server implements a narrower surface than the
/// Node server — notably no `structured`/`screen`/`steer` — so clients feature-detect
/// via `serverInfo` rather than assuming parity.
public enum WireProtocol {
    public static let version = 1
    public static let capabilities = ["queue", "trackedPrs", "editor", "terminal", "adoptExternal", "inputAck", "resizeAck", "screen"]
}

public enum ServerMessage: Sendable {
    /// Sent once, immediately on connect, before any other message: the server's
    /// wire-protocol version + implemented capabilities, for client feature
    /// detection (juancode-tgc).
    case serverInfo(protocolVersion: Int, capabilities: [String])
    case created(session: SessionMeta)
    case attached(sessionId: String, scrollback: String, session: SessionMeta)
    case output(sessionId: String, data: String)
    /// A frame of the live rendered-screen stream (juancode-a2h.3), projected from
    /// the session's headless terminal model — not re-parsed from bytes.
    /// `reset: true` carries the full grid (every row) — sent first after
    /// `subscribeScreen` and again whenever the geometry or screen buffer flips;
    /// `reset: false` carries only the rows that changed since the last frame.
    /// Only sent to connections that opted in via `subscribeScreen`.
    case screen(sessionId: String, reset: Bool, cols: Int, rows: Int,
                cursorX: Int, cursorY: Int, cursorVisible: Bool, alt: Bool,
                lines: [ScreenRowWire])
    /// Acknowledgement that the server wrote an `input` carrying a `seq`
    /// (juancode-1u3) — echoes `sessionId` + `seq` so the client clears that
    /// keystroke from its unacked buffer. Only sent when the input carried a seq.
    case inputAck(sessionId: String, seq: Int)
    /// Acknowledgement that the server processed a `resize` carrying a `seq`
    /// (juancode-uz6). `cols`/`rows` echo the requested grid; `applied` is true only
    /// when the grid reached a live pty (false when it wasn't running yet). The
    /// client re-asserts its latest grid on `applied: false`. `denied` is true when
    /// another client owns the session's shared grid (juancode-1th.1): the resize
    /// was intentionally NOT applied and re-sending it is futile, so the client
    /// stops retrying and renders the pty's actual grid as-is. Only sent when the
    /// resize carried a seq.
    case resizeAck(sessionId: String, seq: Int, cols: Int, rows: Int, applied: Bool, denied: Bool)
    case exit(sessionId: String, exitCode: Int?)
    case activity(sessionId: String, state: SessionActivity, notify: Bool)
    /// A session's current pending message queue (oracle-cj3 / juancode-r82) — sent
    /// on `subscribeQueue` and after every change (queued, delivered, cancelled).
    /// Always the complete ordered list; replace wholesale.
    case queue(sessionId: String, items: [QueuedMessage])
    case editorReady(editorId: String)
    case terminalReady(terminalId: String, requestId: String)
    case unresumable(sessionId: String, reason: String)
    case error(sessionId: String?, message: String)
    // ── Tracked-PR registry (juancode-bt2) — keep beside the PR REST types ───────
    /// The full tracked-PR watch list — sent on `subscribeTrackedPrs` and after
    /// every change/poll. Always the complete set, replace wholesale.
    case trackedPrs(tracked: [TrackedPr])
    /// A single needs-decision escalation fired for a tracked PR (the agent should
    /// NOT auto-apply it) — a ping the client can alert on without diffing the list.
    case trackNotification(trackedId: String, prNumber: Int, notification: TrackNotification)
}

/// Wire shape of a tracked PR (juancode-bt2). A hand-built mirror of `TrackedPr`
/// reduced to what the remote client needs, encoding the badge `state` and
/// notifications explicitly so the JSON matches `TrackedPrInfo` in the protocol.ts
/// twins byte-for-byte (notably `state: "needs_decision"`, snake-cased on the wire,
/// vs. Swift's `TrackState.needsDecision`).
struct TrackedPrWire: Encodable {
    let id: String
    let number: Int
    let title: String
    let branch: String
    let url: String
    let cwd: String
    let sessionId: String
    let state: String
    let checks: PrChecks
    let notifications: [TrackNotification]
    let lastPolledAt: Int?

    init(_ p: TrackedPr) {
        id = p.id; number = p.number; title = p.title; branch = p.branch; url = p.url
        cwd = p.cwd; sessionId = p.sessionId; checks = p.snapshot.checks
        notifications = p.notifications; lastPolledAt = p.lastPolledAt
        switch p.state {
        case .watching: state = "watching"
        case .fixing: state = "fixing"
        case .needsDecision: state = "needs_decision"
        }
    }
}

extension ServerMessage: Encodable {
    private enum K: String, CodingKey {
        case type, session, sessionId, scrollback, data, exitCode, state, notify
        case editorId, terminalId, requestId, reason, message
        // Version/capability handshake (juancode-tgc).
        case protocolVersion, capabilities
        // Input acknowledgement (juancode-1u3).
        case seq
        // Resize acknowledgement (juancode-uz6) + grid-ownership deny (juancode-1th.1).
        case cols, rows, applied, denied
        // Tracked-PR registry (juancode-bt2).
        case tracked, trackedId, prNumber, notification
        // Per-session message queue (oracle-cj3 / juancode-r82).
        case items
        // Rendered-screen stream (juancode-a2h.3).
        case reset, cursorX, cursorY, cursorVisible, alt, lines
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .serverInfo(protocolVersion, capabilities):
            try c.encode("serverInfo", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(capabilities, forKey: .capabilities)
        case let .created(session):
            try c.encode("created", forKey: .type)
            try c.encode(session, forKey: .session)
        case let .attached(sessionId, scrollback, session):
            try c.encode("attached", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(scrollback, forKey: .scrollback)
            try c.encode(session, forKey: .session)
        case let .output(sessionId, data):
            try c.encode("output", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(data, forKey: .data)
        case let .screen(sessionId, reset, cols, rows, cursorX, cursorY, cursorVisible, alt, lines):
            try c.encode("screen", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(reset, forKey: .reset)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(cursorX, forKey: .cursorX)
            try c.encode(cursorY, forKey: .cursorY)
            try c.encode(cursorVisible, forKey: .cursorVisible)
            try c.encode(alt, forKey: .alt)
            try c.encode(lines, forKey: .lines)
        case let .inputAck(sessionId, seq):
            try c.encode("inputAck", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(seq, forKey: .seq)
        case let .resizeAck(sessionId, seq, cols, rows, applied, denied):
            try c.encode("resizeAck", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(seq, forKey: .seq)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(applied, forKey: .applied)
            try c.encode(denied, forKey: .denied)
        case let .exit(sessionId, exitCode):
            try c.encode("exit", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            // `exitCode: number | null` is always present in the TS — emit null,
            // not an omitted key, when there's no code.
            try c.encode(exitCode, forKey: .exitCode)
        case let .activity(sessionId, state, notify):
            try c.encode("activity", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(state, forKey: .state)
            try c.encode(notify, forKey: .notify)
        case let .queue(sessionId, items):
            try c.encode("queue", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(items, forKey: .items)
        case let .editorReady(editorId):
            try c.encode("editorReady", forKey: .type)
            try c.encode(editorId, forKey: .editorId)
        case let .terminalReady(terminalId, requestId):
            try c.encode("terminalReady", forKey: .type)
            try c.encode(terminalId, forKey: .terminalId)
            try c.encode(requestId, forKey: .requestId)
        case let .unresumable(sessionId, reason):
            try c.encode("unresumable", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(reason, forKey: .reason)
        case let .error(sessionId, message):
            try c.encode("error", forKey: .type)
            // `sessionId?` is optional in the TS — omit when nil.
            try c.encodeIfPresent(sessionId, forKey: .sessionId)
            try c.encode(message, forKey: .message)
        case let .trackedPrs(tracked):
            try c.encode("trackedPrs", forKey: .type)
            try c.encode(tracked.map(TrackedPrWire.init), forKey: .tracked)
        case let .trackNotification(trackedId, prNumber, notification):
            try c.encode("trackNotification", forKey: .type)
            try c.encode(trackedId, forKey: .trackedId)
            try c.encode(prNumber, forKey: .prNumber)
            try c.encode(notification, forKey: .notification)
        }
    }

    /// JSON string for sending over the socket.
    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
