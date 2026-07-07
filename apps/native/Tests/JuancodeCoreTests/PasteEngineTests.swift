import Testing
@testable import JuancodeCore

/// Unit tests for the pure paste-pipeline planner that backs `Session`'s
/// programmatic text delivery (`insert` / `submit` / seed / queue flush).
@Suite struct PasteEngineTests {
    /// Decode a plan's chunks back into the full byte stream for assertions.
    private func bytes(of plan: PasteEngine.Plan) -> [UInt8] {
        guard case let .deliver(chunks) = plan else { return [] }
        return chunks.flatMap { $0 }
    }

    private func text(of plan: PasteEngine.Plan) -> String {
        String(decoding: bytes(of: plan), as: UTF8.self)
    }

    @Test func wrapsSmallPasteInBracketedMarkers() {
        let plan = PasteEngine.plan("hello world")
        #expect(text(of: plan) == "\u{1B}[200~hello world\u{1B}[201~")
    }

    @Test func rawDeliveryWhenBracketingDisabled() {
        var policy = PasteEngine.Policy.agentPrompt
        policy.bracketed = false
        let plan = PasteEngine.plan("hello world", policy: policy)
        #expect(text(of: plan) == "hello world")
    }

    @Test func normalizesCrlfAndLoneCrToLf() {
        var policy = PasteEngine.Policy.agentPrompt
        policy.bracketed = false
        let plan = PasteEngine.plan("a\r\nb\rc\nd", policy: policy)
        #expect(text(of: plan) == "a\nb\nc\nd")
    }

    @Test func keepsNewlinesWhenNormalizationDisabled() {
        var policy = PasteEngine.Policy(bracketed: false, normalizeNewlines: false)
        let plan = PasteEngine.plan("a\r\nb", policy: policy)
        #expect(text(of: plan) == "a\r\nb")
    }

    @Test func stripsEmbeddedPasteMarkersToPreventEarlyClose() {
        // A payload carrying its own end-marker must not be able to close the paste
        // early and let the tail be read as keystrokes.
        let plan = PasteEngine.plan("safe\u{1B}[201~evil\u{1B}[200~more")
        #expect(text(of: plan) == "\u{1B}[200~safeevilmore\u{1B}[201~")
    }

    @Test func emptyContentDeliversNothing() {
        // stripping/normalizing can't empty a non-empty string here, but an
        // all-empty input yields no chunks (delivery no-ops).
        if case let .deliver(chunks) = PasteEngine.plan("") {
            #expect(chunks.isEmpty)
        } else {
            Issue.record("expected .deliver for empty input")
        }
    }

    @Test func rejectsOverTheSizeLimit() {
        var policy = PasteEngine.Policy.agentPrompt
        policy.maxBytes = 10
        let plan = PasteEngine.plan(String(repeating: "x", count: 11), policy: policy)
        guard case let .reject(reason) = plan else {
            Issue.record("expected .reject over the size limit")
            return
        }
        #expect(reason.contains("too large"))
    }

    @Test func allowsExactlyTheSizeLimit() {
        var policy = PasteEngine.Policy(bracketed: false, maxBytes: 10)
        let plan = PasteEngine.plan(String(repeating: "x", count: 10), policy: policy)
        #expect(text(of: plan) == String(repeating: "x", count: 10))
    }

    @Test func sizeLimitMeasuresContentNotMarkers() {
        // The bracketed markers add ~12 bytes; a content-length limit must not count
        // them, so content at exactly the limit is accepted even bracketed.
        var policy = PasteEngine.Policy.agentPrompt
        policy.maxBytes = 5
        let plan = PasteEngine.plan("12345", policy: policy)
        #expect(text(of: plan) == "\u{1B}[200~12345\u{1B}[201~")
    }

    @Test func chunksLargePayloadWithinChunkSize() {
        var policy = PasteEngine.Policy(bracketed: false, chunkBytes: 4)
        let plan = PasteEngine.plan("abcdefghij", policy: policy)
        guard case let .deliver(chunks) = plan else {
            Issue.record("expected .deliver")
            return
        }
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 4 })
        #expect(text(of: plan) == "abcdefghij")
    }

    @Test func chunkingNeverSplitsAMultiByteCharacter() {
        // Each emoji is 4 UTF-8 bytes; with a 4-byte chunk cap every chunk must hold
        // exactly one whole emoji, never a half.
        var policy = PasteEngine.Policy(bracketed: false, chunkBytes: 4)
        let plan = PasteEngine.plan("😀😀😀", policy: policy)
        guard case let .deliver(chunks) = plan else {
            Issue.record("expected .deliver")
            return
        }
        #expect(chunks.count == 3)
        for chunk in chunks {
            #expect(String(decoding: chunk, as: UTF8.self) == "😀")
        }
    }

    @Test func markersRideTheBoundaryChunksWhenChunked() {
        var policy = PasteEngine.Policy(bracketed: true, chunkBytes: 4)
        let plan = PasteEngine.plan("abcdef", policy: policy)
        guard case let .deliver(chunks) = plan, let first = chunks.first, let last = chunks.last else {
            Issue.record("expected non-empty .deliver")
            return
        }
        #expect(first.starts(with: PasteEngine.startMarker))
        #expect(last.suffix(PasteEngine.endMarker.count) == PasteEngine.endMarker[...])
        // Reassembled stream is still the single well-formed bracketed paste.
        #expect(text(of: plan) == "\u{1B}[200~abcdef\u{1B}[201~")
    }

    @Test func reassembledStreamRoundTripsMultilineContent() {
        let body = "line one\nline two\n\nline four with trailing"
        let plan = PasteEngine.plan(body)
        #expect(text(of: plan) == "\u{1B}[200~\(body)\u{1B}[201~")
    }
}
