import Foundation
import Testing
@testable import JuancodeCore

/// The allocation-free gate matching behind `ActivityDetector`'s hot path
/// (juancode-zazn): it must answer exactly what the old
/// `String.lowercased().contains(...)` did.
@Suite struct ByteSearchTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func findsAnAsciiNeedleRegardlessOfCase() {
        #expect(ByteSearch.contains(bytes("… (esc to INTERRUPT)"), bytes("interrupt")))
        #expect(ByteSearch.contains(bytes("Do You Trust this folder?"), bytes("trust")))
        #expect(!ByteSearch.contains(bytes("nothing to see"), bytes("interrupt")))
    }

    @Test func matchesAtTheVeryStartAndEnd() {
        #expect(ByteSearch.contains(bytes("interrupt now"), bytes("interrupt")))
        #expect(ByteSearch.contains(bytes("press esc to interrupt"), bytes("interrupt")))
    }

    @Test func matchesAMultibyteTokenLiterally() {
        #expect(ByteSearch.contains(bytes(" ❯ 1. Yes"), bytes("❯")))
        // A different glyph sharing a UTF-8 lead byte must not match.
        #expect(!ByteSearch.contains(bytes(" ✻ thinking"), bytes("❯")))
    }

    @Test func handlesDegenerateInputs() {
        #expect(!ByteSearch.contains(bytes("short"), bytes("much longer needle")))
        #expect(!ByteSearch.contains([], bytes("x")))
        #expect(!ByteSearch.contains(bytes("abc"), []))
    }

    @Test func matchesNonLetterBytesExactly() {
        #expect(ByteSearch.contains(bytes("continue? (y/n)"), bytes("y/n")))
        #expect(!ByteSearch.contains(bytes("continue (yes/no)"), bytes("y/n")))
    }

    @Test func containsAnyMatchesTheFirstHit() {
        let needles = [bytes("trust"), bytes("y/n"), bytes("❯")]
        #expect(ByteSearch.containsAny(bytes("select: ❯ 1."), needles))
        #expect(!ByteSearch.containsAny(bytes("plain streamed output"), needles))
    }

    /// Case folding is ASCII-only: a non-ASCII byte is never altered, so multibyte
    /// sequences can't be mangled into a false match.
    @Test func doesNotFoldNonAsciiBytes() {
        #expect(!ByteSearch.contains([0xC3, 0x89], [0xC3, 0xA9])) // É vs é
    }
}
