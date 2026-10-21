import Foundation

/// A chain's color, picked from its slug: the same chain is the same color on every
/// surface, in every window, after every relaunch, so a badge on a sidebar row and one
/// on a PR row read as the same group before the slug is read.
///
/// The slug is the only input on purpose. It never changes (see `Chain`), and anything
/// stored per chain would have to travel on the wire for two clients to agree.
public enum ChainPalette {
    /// One color in HSB, each component 0...1.
    public struct Tone: Equatable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var brightness: Double
    }

    /// The hues chains are spread over, around the wheel. Hand-placed rather than
    /// evenly spaced: an even step lands two of them on yellow-greens that are hard to
    /// tell apart and muddy on a light background.
    public static let hues: [Double] = [
        0.00, 0.06, 0.11, 0.25, 0.36, 0.47, 0.54, 0.61, 0.69, 0.77, 0.84, 0.92,
    ]

    /// Which of `hues` a slug gets.
    public static func slot(for slug: String) -> Int {
        Int(fnv1a(slug) % UInt64(hues.count))
    }

    /// The slug's color. Dark mode lifts brightness and drops saturation so the text
    /// stays readable on black; light mode darkens it for the same reason on white.
    public static func tone(for slug: String, dark: Bool) -> Tone {
        let hue = hues[slot(for: slug)]
        return dark
            ? Tone(hue: hue, saturation: 0.55, brightness: 0.95)
            : Tone(hue: hue, saturation: 0.80, brightness: 0.62)
    }

    /// FNV-1a over the UTF-8 bytes. Not `hashValue`, which Swift seeds per process and
    /// would recolor every chain on each launch.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
