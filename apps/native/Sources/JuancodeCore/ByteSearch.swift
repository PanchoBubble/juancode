/// Case-insensitive (ASCII) substring search over raw bytes.
///
/// The activity detector's cheap gates — "does this chunk even mention `interrupt`?"
/// — used to decode every pty chunk into a `String` and `lowercased()` it, i.e. one
/// whole-chunk allocation plus a Unicode case fold per chunk per running session,
/// purely to run a handful of substring checks (juancode-zazn). The gates only look
/// for short ASCII words and one fixed multibyte token, so matching over the bytes
/// gives the same answers with no allocation at all.
public enum ByteSearch {
    /// Whether `haystack` contains `needle`, folding ASCII `A-Z` to lowercase on both
    /// sides. Give `needle` in lowercase; bytes outside `A-Z` compare exactly, so a
    /// UTF-8 token (e.g. `"❯"`) matches literally.
    public static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = fold(needle[0])
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if fold(haystack[i]) == first {
                var j = 1
                while j < needle.count, fold(haystack[i + j]) == fold(needle[j]) { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Whether `haystack` contains any of `needles` (same folding as `contains`).
    public static func containsAny(_ haystack: [UInt8], _ needles: [[UInt8]]) -> Bool {
        needles.contains { contains(haystack, $0) }
    }

    @inline(__always)
    private static func fold(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }
}
