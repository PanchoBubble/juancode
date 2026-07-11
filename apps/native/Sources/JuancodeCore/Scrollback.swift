/// Capped scrollback buffer.
///
/// We keep bytes, not a decoded String: the pty stream is raw and chunk
/// boundaries can split multibyte UTF-8 or escape sequences, so trimming on
/// byte length and replaying bytes verbatim is the faithful choice. Replay feeds
/// these bytes straight into a SwiftTerm `feed(byteArray:)` (or a WS client).
///
/// Trimming the oldest bytes is lossy in one way that matters: a full-screen TUI
/// (claude/codex run on the terminal's *alternate screen*) emits its enter-alt
/// sequence once at startup. A long-running agent overflows the cap, so that
/// sequence gets trimmed away — and a late subscriber then replays the remaining
/// bytes into the *normal* buffer, where the program's absolute cursor moves and
/// redraws land at the wrong offsets → garbage. We therefore track the alt-buffer
/// state across appends and, on `replay`, re-establish it with a synthetic resync
/// prefix so the parser is in the same screen mode the program believes it is.

/// Append `chunk` to `buffer`, keeping at most `limit` trailing bytes.
public func appendScrollback(_ buffer: [UInt8], _ chunk: [UInt8], limit: Int) -> [UInt8] {
    var next = buffer
    next.append(contentsOf: chunk)
    if next.count > limit {
        next.removeFirst(next.count - limit)
    }
    return next
}

/// Mutable wrapper around the capped buffer.
///
/// Storage is a chunked deque — retained pty chunks plus a head offset — rather
/// than a flat array: a flat ring forced a COW copy of the entire retained buffer
/// (up to the cap) on every pty chunk, on the session work queue. Here append is
/// O(chunk) and eviction drops whole chunks from the head; the contiguous view
/// (`bytes`/`replay`) is joined on demand, which only happens on attach/persist.
public struct Scrollback {
    public let limit: Int
    /// Retained chunks, oldest first. The first `headOffset` bytes of `chunks[0]`
    /// are already evicted.
    private var chunks: [[UInt8]] = []
    private var headOffset = 0
    /// Retained byte count (excludes the evicted `headOffset` prefix).
    private var count = 0
    /// Trailing bytes carried across appends so an enter/exit alt sequence split
    /// on a chunk boundary is still detected (the longest token is 8 bytes).
    private var carry: [UInt8] = []
    /// Whether the stream is currently in the terminal's alternate screen buffer.
    /// Tracked across appends so `replay` can re-establish it even after the
    /// original enter-alt sequence has been trimmed past the cap.
    public private(set) var inAlternateBuffer: Bool

    /// Small pty reads are merged into the tail chunk so the deque stays short:
    /// a bounded chunk count keeps head eviction and the lazy join cheap even
    /// under byte-at-a-time output.
    private static let coalesceThreshold = 4096

    public init(limit: Int, seed: [UInt8] = []) {
        self.limit = limit
        var kept = seed.count > limit ? Array(seed.suffix(limit)) : seed
        // A seed produced by `replay` (e.g. a reactivated session's prior history)
        // carries the synthetic resync prefix; drop it so it isn't compounded the
        // next time we replay.
        if kept.starts(with: Scrollback.altResync) {
            kept.removeFirst(Scrollback.altResync.count)
        }
        if !kept.isEmpty {
            self.chunks = [kept]
            self.count = kept.count
        }
        self.carry = Array(kept.suffix(7))
        // Scan the *full* seed, not just the kept tail, so the alt-buffer state is
        // recovered even when its enter sequence sits before the trim point.
        self.inAlternateBuffer = Scrollback.scanAlternate(from: false, scanning: seed)
    }

    public mutating func append(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        let scan = carry + chunk
        inAlternateBuffer = Scrollback.scanAlternate(from: inAlternateBuffer, scanning: scan)
        carry = Array(scan.suffix(7))
        if chunk.count >= limit {
            chunks = [Array(chunk.suffix(limit))]
            headOffset = 0
            count = limit
            return
        }
        if let tailCount = chunks.last?.count,
            tailCount + chunk.count <= Scrollback.coalesceThreshold
        {
            chunks[chunks.count - 1].append(contentsOf: chunk)
        } else {
            chunks.append(chunk)
        }
        count += chunk.count
        var overflow = count - limit
        while overflow > 0 {
            let headAvailable = chunks[0].count - headOffset
            if overflow >= headAvailable {
                chunks.removeFirst()
                headOffset = 0
                count -= headAvailable
                overflow -= headAvailable
            } else {
                headOffset += overflow
                count -= overflow
                overflow = 0
            }
        }
    }

    /// Contiguous retained bytes, joined on demand.
    public var bytes: [UInt8] {
        var joined = [UInt8]()
        joined.reserveCapacity(count)
        for (index, chunk) in chunks.enumerated() {
            if index == 0, headOffset > 0 {
                joined.append(contentsOf: chunk[headOffset...])
            } else {
                joined.append(contentsOf: chunk)
            }
        }
        return joined
    }

    /// Bytes to feed a freshly-attached terminal. In the alternate buffer we prepend
    /// a resync (enter-alt + clear + home) so the parser starts in the right screen
    /// mode; otherwise the raw trailing bytes (normal-buffer scrollback) as before.
    public var replay: [UInt8] {
        inAlternateBuffer ? Scrollback.altResync + bytes : bytes
    }

    /// `ESC[?1049h` (enter alternate screen) + `ESC[2J` (clear) + `ESC[H` (home).
    static let altResync: [UInt8] = [
        0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68,  // ESC [ ? 1 0 4 9 h
        0x1b, 0x5b, 0x32, 0x4a,                          // ESC [ 2 J
        0x1b, 0x5b, 0x48,                                // ESC [ H
    ]

    // DEC private-mode toggles for the alternate screen (xterm 1049/1047, legacy 47).
    private static let enterTokens: [[UInt8]] = [
        [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68],  // ESC[?1049h
        [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x37, 0x68],  // ESC[?1047h
        [0x1b, 0x5b, 0x3f, 0x34, 0x37, 0x68],              // ESC[?47h
    ]
    private static let exitTokens: [[UInt8]] = [
        [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c],  // ESC[?1049l
        [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x37, 0x6c],  // ESC[?1047l
        [0x1b, 0x5b, 0x3f, 0x34, 0x37, 0x6c],              // ESC[?47l
    ]

    /// Walk `data`, returning the alt-buffer state after the last enter/exit token,
    /// starting from `initial`.
    static func scanAlternate(from initial: Bool, scanning data: [UInt8]) -> Bool {
        var state = initial
        var i = 0
        let n = data.count
        while i < n {
            // Only escape sequences toggle the buffer; skip ahead to the next ESC.
            guard data[i] == 0x1b else { i += 1; continue }
            if let tok = enterTokens.first(where: { data[i...].starts(with: $0) }) {
                state = true; i += tok.count; continue
            }
            if let tok = exitTokens.first(where: { data[i...].starts(with: $0) }) {
                state = false; i += tok.count; continue
            }
            i += 1
        }
        return state
    }
}
