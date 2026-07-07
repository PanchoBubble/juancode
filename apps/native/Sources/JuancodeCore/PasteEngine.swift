import Foundation

/// Pure paste-pipeline logic that backs `Session`'s programmatic text delivery
/// (`insert` / `submit` / seed / queue flush). Split out from `Session` so the
/// brittle parts — chunk boundaries, newline policy, bracketed-paste wrapping,
/// size limits — are unit-testable without spinning up a real pty.
///
/// This covers only PROGRAMMATIC delivery (queued messages, palette inserts,
/// auto-submit prompts, review submissions). The interactive keystroke / cmd-V
/// paths owned by the terminal surfaces (GhosttyLive / SwiftTermLive) are left
/// untouched — they write straight to the pty as the user types.
///
/// The engine is a pure planner: given the text and a policy it returns either a
/// friendly rejection (over the size limit) or an ordered list of raw byte
/// chunks to hand the pty. `Session` owns the serialized, backpressured delivery
/// of those chunks and the deliver-then-verify auto-submit dance.
public enum PasteEngine {
    /// Per-delivery policy. Bracketed-paste is program-aware (both claude and
    /// codex enable it, but a future non-bracketed program can opt out via its
    /// `ProviderSpec`). Chunking keeps a single blocking pty write small enough
    /// that the read handler can interleave between chunks — a 2MB burst handed to
    /// the pty in one write can stall the shared work queue (we block writing input
    /// while the child blocks writing output) and truncate on a short write.
    public struct Policy: Sendable, Equatable {
        /// Wrap the whole payload in bracketed-paste markers (`ESC[200~ … ESC[201~`)
        /// so the program reads it as one paste instead of interpreting embedded
        /// newlines as submits.
        public var bracketed: Bool
        /// Max bytes per delivered chunk (markers included on the boundary chunks).
        public var chunkBytes: Int
        /// Reject the paste when the content exceeds this many UTF-8 bytes, with a
        /// friendly error, rather than silently wedging the TUI.
        public var maxBytes: Int
        /// Collapse CRLF and lone CR to LF inside the content. A literal CR left in
        /// a bracketed paste is read as an Enter by the CLI's line editor — the
        /// "paste with a literal CR never submits / submits early" class of bug — so
        /// normalizing to LF keeps the whole payload as one multi-line block.
        public var normalizeNewlines: Bool

        public init(bracketed: Bool = true,
                    chunkBytes: Int = 8 * 1024,
                    maxBytes: Int = 2 * 1024 * 1024,
                    normalizeNewlines: Bool = true) {
            self.bracketed = bracketed
            self.chunkBytes = max(1, chunkBytes)
            self.maxBytes = max(0, maxBytes)
            self.normalizeNewlines = normalizeNewlines
        }

        /// The policy for delivering text into an agent prompt: bracketed, 8KB
        /// chunks, 2MB ceiling, newlines normalized.
        public static let agentPrompt = Policy()
    }

    /// The computed delivery plan.
    public enum Plan: Sendable, Equatable {
        /// Over the size limit — carries a user-facing reason.
        case reject(reason: String)
        /// Ordered raw byte chunks to write to the pty, in sequence. Empty when the
        /// content is empty (nothing to deliver).
        case deliver(chunks: [[UInt8]])
    }

    /// Bracketed-paste start / end control sequences.
    static let startMarker: [UInt8] = Array("\u{1B}[200~".utf8)
    static let endMarker: [UInt8] = Array("\u{1B}[201~".utf8)

    /// Plan the delivery of `text` under `policy`.
    ///
    /// Steps: normalize newlines, strip any embedded bracketed-paste markers (a
    /// payload containing `ESC[201~` would otherwise close the paste early and let
    /// the rest be interpreted as keystrokes — a garble / injection hazard), check
    /// the size limit, then wrap + chunk on grapheme boundaries so a multi-byte
    /// character is never split across two writes.
    public static func plan(_ text: String, policy: Policy = .agentPrompt) -> Plan {
        var content = text
        if policy.normalizeNewlines {
            content = normalizeNewlines(content)
        }
        content = stripPasteMarkers(content)

        let contentBytes = content.utf8.count
        if contentBytes > policy.maxBytes {
            return .reject(reason: sizeRejection(bytes: contentBytes, limit: policy.maxBytes))
        }
        if content.isEmpty {
            return .deliver(chunks: [])
        }

        var chunks = chunkOnGraphemeBoundaries(content, maxBytes: policy.chunkBytes)
        if policy.bracketed {
            chunks[0].insert(contentsOf: startMarker, at: 0)
            chunks[chunks.count - 1].append(contentsOf: endMarker)
        }
        return .deliver(chunks: chunks)
    }

    // MARK: - pure helpers

    /// Collapse `\r\n` and lone `\r` to `\n`.
    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Remove any embedded bracketed-paste start/end markers so a pasted payload
    /// can't terminate its own paste early.
    static func stripPasteMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")
    }

    /// Split `s` into UTF-8 byte chunks each ≤ `maxBytes`, cutting only on grapheme
    /// boundaries so no code point (or combining sequence) straddles two chunks. A
    /// lone grapheme larger than `maxBytes` becomes its own (over-size) chunk rather
    /// than being split. Always returns at least one chunk for non-empty input.
    static func chunkOnGraphemeBoundaries(_ s: String, maxBytes: Int) -> [[UInt8]] {
        let cap = max(1, maxBytes)
        var chunks: [[UInt8]] = []
        var current: [UInt8] = []
        for character in s {
            let bytes = Array(String(character).utf8)
            if !current.isEmpty && current.count + bytes.count > cap {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: bytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A human-readable "too large" message with rounded MB figures.
    static func sizeRejection(bytes: Int, limit: Int) -> String {
        "Paste is too large (\(mb(bytes))). The limit is \(mb(limit)) — trim it or hand the CLI a file instead."
    }

    private static func mb(_ bytes: Int) -> String {
        let value = Double(bytes) / (1024 * 1024)
        if value >= 10 { return "\(Int(value.rounded())) MB" }
        return String(format: "%.1f MB", value)
    }
}

/// The result of a programmatic paste into a live session.
public enum PasteOutcome: Sendable, Equatable {
    /// All chunks were written (and the submitting Enter sent, for `submit`).
    case delivered
    /// Refused before delivery — over the size limit. Carries a user-facing reason.
    case rejected(reason: String)
    /// Delivery could not complete — the session died mid-paste or a chunk write
    /// stalled past the operation timeout. Fails loudly to the caller instead of
    /// hanging.
    case aborted(reason: String)
}
