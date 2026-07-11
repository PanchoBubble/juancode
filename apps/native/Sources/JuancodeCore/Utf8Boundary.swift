import Foundation

/// Boundary math for incrementally decoding a UTF-8 byte stream that can be
/// split anywhere (a pty read, a coalesced output flush): find where the last
/// complete scalar ends so an incomplete trailing multibyte sequence can be
/// carried into the next chunk, instead of decoding to replacement characters
/// on both sides of the split.
public enum Utf8Boundary {
    /// Length of the longest prefix of `buf` that ends on a UTF-8 scalar
    /// boundary — excludes an incomplete multibyte sequence at the tail (at
    /// most 3 bytes) so it can be carried into the next chunk. A malformed or
    /// all-continuation tail is left in the prefix (returns the full count) so
    /// behavior matches a whole-chunk decode: replaced, never held back.
    public static func completePrefixLength(_ buf: [UInt8]) -> Int {
        let n = buf.count
        guard n > 0 else { return 0 }
        // Walk back over up to 3 continuation bytes (10xxxxxx) to the last lead byte.
        var i = n - 1
        var conts = 0
        while i >= 0, buf[i] & 0xC0 == 0x80, conts < 3 { i -= 1; conts += 1 }
        guard i >= 0 else { return n } // all-continuation tail: malformed, don't carry
        let expected = sequenceLength(buf[i])
        // Carry only a real multibyte lead whose continuation bytes haven't all arrived.
        if expected >= 2, n - i < expected { return i }
        return n
    }

    /// Total byte length a UTF-8 sequence should have given its lead byte: 1 for
    /// ASCII, 2/3/4 for multibyte leads, 0 for a continuation byte or invalid lead.
    private static func sequenceLength(_ b: UInt8) -> Int {
        if b & 0x80 == 0 { return 1 } // 0xxxxxxx
        if b & 0xE0 == 0xC0 { return 2 } // 110xxxxx
        if b & 0xF0 == 0xE0 { return 3 } // 1110xxxx
        if b & 0xF8 == 0xF0 { return 4 } // 11110xxx
        return 0 // 10xxxxxx continuation, or invalid
    }
}
