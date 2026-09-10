import Foundation
import JuancodeCore

/// The Agent Client Protocol vocabulary juancode consumes, and the mapping from it
/// onto the seam kinds `ActivityDetector` already speaks.
///
/// ACP is a second way to drive an agent: instead of parsing a pseudo-terminal, the
/// agent runs as a child process and reports turns, reasoning, tool calls and usage
/// as structured JSON-RPC notifications. This file is the reading half — what an
/// agent says. `ACPStdioTransport` carries it; `ACPAgentClient` drives a turn.
///
/// Every shape here was read off a real frame log, not off the spec: `opencode acp`
/// (1.18.25) driven through initialize → session/new → session/prompt with a prompt
/// that forces reasoning and a shell tool call. Two things that log taught us and a
/// spec reading would not:
///
/// - Text arrives in very small pieces. One 290-character thought came as 21
///   `agent_thought_chunk` notifications. Anything downstream that treats a
///   notification as an event sees 21 thoughts for one, which is why `ACPSeamStream`
///   coalesces runs rather than forwarding chunks.
/// - `tool_call_update` repeats. The same call reported `in_progress` three times
///   before `completed`, so resolution has to be deduplicated by `toolCallId` or the
///   detector is told a call finished several times.
///
/// What ACP does *not* solve is recorded on juancode-6582: claude emits zero
/// reasoning here over ACP too, because the thinking blocks it produces are empty
/// (juancode-bqw0). opencode is the one agent on this machine that supplies the text.

// MARK: - What an agent reports

/// One tool call as ACP describes it, folded across its `tool_call` opening and the
/// `tool_call_update`s that follow: the updates carry only the fields that changed,
/// so a later frame with no `title` must not erase the one the opening frame set.
public struct ACPToolCall: Sendable, Equatable {
    public enum Status: String, Sendable {
        case pending, inProgress = "in_progress", completed, failed
        /// True once the call can no longer produce anything, which is when the seam
        /// gets its `tool_result`.
        var isTerminal: Bool { self == .completed || self == .failed }
    }

    public var id: String
    public var title: String?
    /// The agent's own category for the call — "execute", "read", "edit", … Kept as
    /// the string it arrived as: it is a display hint, and inventing an enum here
    /// would turn an unknown kind from a label into a decode failure.
    public var kind: String?
    public var status: Status
    /// Paths the call touches, for a view that wants to show what it is working on.
    public var locations: [String]
    /// The call's output text, flattened from `content[]` on completion.
    public var output: String?

    public init(id: String, title: String? = nil, kind: String? = nil,
                status: Status = .pending, locations: [String] = [], output: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.locations = locations
        self.output = output
    }

    /// Fold a later `tool_call_update` into this call, keeping fields it omitted.
    mutating func merge(_ other: ACPToolCall) {
        status = other.status
        if let t = other.title { title = t }
        if let k = other.kind { kind = k }
        if !other.locations.isEmpty { locations = other.locations }
        if let o = other.output { output = o }
    }
}

/// Context and spend as the agent reports it mid-turn (`usage_update`).
public struct ACPUsage: Sendable, Equatable {
    /// Context tokens consumed so far, and the window they are consumed from.
    public var used: Int
    public var size: Int
    public var costAmount: Double?
    public var costCurrency: String?

    public init(used: Int, size: Int, costAmount: Double? = nil, costCurrency: String? = nil) {
        self.used = used
        self.size = size
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }
}

/// One decoded `session/update` notification.
///
/// The unrecognised case is deliberate and carries its discriminator: ACP agents add
/// update kinds (`available_commands_update`, `current_mode_update` and `plan` all
/// showed up unasked in the probe), and an adapter that throws on an unknown kind
/// breaks on the next agent release for no benefit.
public enum ACPUpdate: Sendable, Equatable {
    case agentMessage(messageId: String?, text: String)
    case agentThought(messageId: String?, text: String)
    case userMessage(messageId: String?, text: String)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCall)
    case usage(ACPUsage)
    case unhandled(String)

    /// Decode the `params` object of a `session/update` notification.
    public static func decode(_ params: [String: Any]) -> ACPUpdate? {
        guard let update = params["update"] as? [String: Any],
              let discriminator = update["sessionUpdate"] as? String else { return nil }
        let messageId = update["messageId"] as? String

        switch discriminator {
        case "agent_message_chunk":
            return .agentMessage(messageId: messageId, text: chunkText(update))
        case "agent_thought_chunk":
            return .agentThought(messageId: messageId, text: chunkText(update))
        case "user_message_chunk":
            return .userMessage(messageId: messageId, text: chunkText(update))
        case "tool_call":
            return toolCall(update).map { .toolCall($0) }
        case "tool_call_update":
            return toolCall(update).map { .toolCallUpdate($0) }
        case "usage_update":
            guard let used = update["used"] as? Int, let size = update["size"] as? Int else { return nil }
            let cost = update["cost"] as? [String: Any]
            return .usage(ACPUsage(used: used, size: size,
                                   costAmount: (cost?["amount"] as? NSNumber)?.doubleValue,
                                   costCurrency: cost?["currency"] as? String))
        default:
            return .unhandled(discriminator)
        }
    }

    /// A chunk's payload is `content: {type: "text", text: "..."}`. Non-text content
    /// (images) has no text and contributes nothing to a transcript run.
    private static func chunkText(_ update: [String: Any]) -> String {
        guard let content = update["content"] as? [String: Any] else { return "" }
        return content["text"] as? String ?? ""
    }

    private static func toolCall(_ update: [String: Any]) -> ACPToolCall? {
        guard let id = update["toolCallId"] as? String else { return nil }
        let locations = (update["locations"] as? [Any] ?? []).compactMap {
            ($0 as? [String: Any])?["path"] as? String
        }
        return ACPToolCall(
            id: id,
            title: update["title"] as? String,
            kind: update["kind"] as? String,
            status: (update["status"] as? String).flatMap(ACPToolCall.Status.init) ?? .pending,
            locations: locations,
            output: flattenContent(update["content"]))
    }

    /// A completed call reports `content: [{type: "content", content: {type: "text",
    /// text}}]`. The nesting is ACP's, not a mistake: the outer object says *how* the
    /// block is carried, the inner one is the block.
    private static func flattenContent(_ value: Any?) -> String? {
        guard let blocks = value as? [Any] else { return nil }
        var text = ""
        for block in blocks {
            guard let block = block as? [String: Any] else { continue }
            if let inner = block["content"] as? [String: Any], let t = inner["text"] as? String {
                text += t
            } else if let t = block["text"] as? String {
                text += t
            }
        }
        return text.isEmpty ? nil : text
    }
}

// MARK: - Onto the seam

/// One contiguous piece of an ACP turn, as a transcript view would render it.
///
/// Text blocks are accumulated, not chunked: a run of `agent_thought_chunk`
/// notifications sharing a `messageId` is one block whose text grows. That is the
/// only shape a reasoning view can use — 21 blocks of "The", " user asks a", " r"
/// is not reasoning anyone can read.
public enum ACPTranscriptBlock: Sendable, Equatable {
    case text(kind: StructuredEventKind, messageId: String?, text: String)
    case tool(ACPToolCall)
}

/// Folds a stream of `ACPUpdate`s into transcript blocks, and reports each one as a
/// `StructuredEventBatch` — the same normalized shape `ActivityDetector` already
/// consumes from the jsonl/sqlite transcript tails.
///
/// The point of the type is that both halves come from one pass: the kinds keep the
/// busy/idle signal wording-independent, and the blocks carry the text the jsonl
/// route cannot supply. A caller that only wants activity can ignore `blocks`.
///
/// Ingestion happens on whichever thread the transport hands notifications to; reads
/// come from wherever a view asks. Both go through one lock, so a caller can read the
/// transcript mid-turn without racing the agent that is still writing it.
public final class ACPSeamStream: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlocks: [ACPTranscriptBlock] = []
    private var storedUsage: ACPUsage?

    /// Every block so far, in arrival order.
    public var blocks: [ACPTranscriptBlock] { lock.withLock { storedBlocks } }
    /// The most recent `usage_update`, or nil if the agent never sent one.
    public var usage: ACPUsage? { lock.withLock { storedUsage } }

    /// Which block index a still-growing text run is appending to, and what run it
    /// is. A run ends when the kind changes, the `messageId` changes, or a tool call
    /// interrupts it.
    private var openRun: (index: Int, kind: StructuredEventKind, messageId: String?)?
    private var openToolCalls: [String: Int] = [:]
    private var resolvedToolCalls: Set<String> = []

    public init() {}

    /// Ingest one update and return the seam events it produced. An update that only
    /// extends a run in progress produces no events — the run was already reported.
    @discardableResult
    public func ingest(_ update: ACPUpdate) -> StructuredEventBatch {
        lock.withLock { ingestLocked(update) }
    }

    /// Blocks of one kind, joined — how a reasoning view asks for the turn's thinking.
    public func text(of kind: StructuredEventKind) -> String {
        lock.withLock {
            storedBlocks.compactMap {
                if case let .text(k, _, text) = $0, k == kind { return text }
                return nil
            }.joined(separator: "\n")
        }
    }

    private func ingestLocked(_ update: ACPUpdate) -> StructuredEventBatch {
        switch update {
        case let .agentMessage(messageId, text):
            return appendText(.assistant, messageId, text)
        case let .agentThought(messageId, text):
            return appendText(.thinking, messageId, text)
        case let .userMessage(messageId, text):
            return appendText(.user, messageId, text)
        case let .toolCall(call):
            return open(call)
        case let .toolCallUpdate(call):
            return applyUpdate(call)
        case let .usage(u):
            storedUsage = u
            return StructuredEventBatch(kinds: [])
        case .unhandled:
            return StructuredEventBatch(kinds: [])
        }
    }

    private func appendText(_ kind: StructuredEventKind, _ messageId: String?, _ text: String) -> StructuredEventBatch {
        // A chunk with no text (an image block, or a keepalive) neither opens a run
        // nor pulses the detector.
        guard !text.isEmpty else { return StructuredEventBatch(kinds: []) }

        if let run = openRun, run.kind == kind, run.messageId == messageId,
           case let .text(k, mid, existing) = storedBlocks[run.index] {
            storedBlocks[run.index] = .text(kind: k, messageId: mid, text: existing + text)
            return StructuredEventBatch(kinds: [])
        }

        storedBlocks.append(.text(kind: kind, messageId: messageId, text: text))
        openRun = (storedBlocks.count - 1, kind, messageId)
        return StructuredEventBatch(kinds: [kind])
    }

    private func open(_ call: ACPToolCall) -> StructuredEventBatch {
        openRun = nil
        // An agent may report the same call twice; only the first opening counts, or
        // the detector holds busy on a call it already saw.
        if let index = openToolCalls[call.id] {
            if case .tool(var existing) = storedBlocks[index] {
                existing.merge(call)
                storedBlocks[index] = .tool(existing)
            }
            return StructuredEventBatch(kinds: [])
        }
        storedBlocks.append(.tool(call))
        openToolCalls[call.id] = storedBlocks.count - 1
        return StructuredEventBatch(kinds: [.toolUse], openedToolUseIds: [call.id])
    }

    private func applyUpdate(_ call: ACPToolCall) -> StructuredEventBatch {
        var batch = StructuredEventBatch(kinds: [])
        // An update for a call we never saw open still has to open it: dropping it
        // would leave the result unpaired, and the detector pairs by id.
        if openToolCalls[call.id] == nil {
            batch = open(call)
        } else if let index = openToolCalls[call.id], case .tool(var existing) = storedBlocks[index] {
            existing.merge(call)
            storedBlocks[index] = .tool(existing)
        }
        guard call.status.isTerminal, resolvedToolCalls.insert(call.id).inserted else { return batch }
        batch.kinds.append(.toolResult)
        batch.resolvedToolUseIds.append(call.id)
        return batch
    }
}
