//! Boundary math for a UTF-8 byte stream that can split anywhere — a port of
//! `Utf8Boundary.swift`. Without this, a multibyte glyph straddling two pty reads
//! decodes to replacement characters on both sides of the split.

/// Length of the longest prefix of `buf` ending on a UTF-8 scalar boundary. An
/// incomplete trailing sequence (at most 3 bytes) is excluded so the caller can
/// carry it into the next chunk. A malformed or all-continuation tail stays in the
/// prefix, matching a whole-chunk decode: replaced, never held back.
pub fn complete_prefix_len(buf: &[u8]) -> usize {
    let n = buf.len();
    if n == 0 {
        return 0;
    }
    let mut i = n as isize - 1;
    let mut conts = 0;
    while i >= 0 && buf[i as usize] & 0xC0 == 0x80 && conts < 3 {
        i -= 1;
        conts += 1;
    }
    if i < 0 {
        return n; // all-continuation tail: malformed, don't carry
    }
    let expected = sequence_len(buf[i as usize]);
    if expected >= 2 && n - (i as usize) < expected {
        return i as usize;
    }
    n
}

fn sequence_len(b: u8) -> usize {
    if b & 0x80 == 0 {
        1
    } else if b & 0xE0 == 0xC0 {
        2
    } else if b & 0xF0 == 0xE0 {
        3
    } else if b & 0xF8 == 0xF0 {
        4
    } else {
        0
    }
}

/// Accumulates pty bytes and hands back only whole scalars, carrying a split
/// sequence across chunks. One per connection per session.
#[derive(Debug, Default)]
pub struct Utf8Stream {
    carry: Vec<u8>,
}

impl Utf8Stream {
    /// Decode what is complete, keeping any partial tail for the next call.
    pub fn push(&mut self, bytes: &[u8]) -> String {
        self.carry.extend_from_slice(bytes);
        let cut = complete_prefix_len(&self.carry);
        let text = String::from_utf8_lossy(&self.carry[..cut]).to_string();
        self.carry.drain(..cut);
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_split_multibyte_glyph_survives_the_split() {
        let glyph = "→".as_bytes(); // 3 bytes
        let mut s = Utf8Stream::default();
        assert_eq!(s.push(&glyph[..2]), "");
        assert_eq!(s.push(&glyph[2..]), "→");
    }

    #[test]
    fn ascii_passes_straight_through() {
        let mut s = Utf8Stream::default();
        assert_eq!(s.push(b"plain"), "plain");
    }

    #[test]
    fn a_malformed_tail_is_not_held_back_forever() {
        assert_eq!(complete_prefix_len(&[0x80, 0x80, 0x80]), 3);
        let mut s = Utf8Stream::default();
        assert_eq!(s.push(&[0x80]).chars().count(), 1);
    }

    #[test]
    fn a_four_byte_emoji_split_three_ways_still_arrives_once() {
        let bytes = "🚀".as_bytes();
        let mut s = Utf8Stream::default();
        assert_eq!(s.push(&bytes[..1]), "");
        assert_eq!(s.push(&bytes[1..3]), "");
        assert_eq!(s.push(&bytes[3..]), "🚀");
    }
}
