//! Reading the new bytes of a file that is still being written.
//!
//! A claude transcript is appended to for as long as the session lives and read on
//! every poll, so the only affordable shape is "read from where we stopped". That is
//! easy to write and easy to get wrong, because the file is allowed to move under the
//! offset in several different ways, and every one of them happens in practice:
//!
//! - **It grows while we read.** `stat` gives one size and the CLI writes more before
//!   the read finishes. We read exactly the bytes `stat` promised and nothing past
//!   them, so the tail's own view of the file never depends on how long the read took.
//! - **The last line is partial.** The CLI writes a record with several `write`s, so
//!   the tail routinely sees half a JSON object. Everything up to the final newline is
//!   returned; the remainder stays unconsumed and is read again next time, whole.
//! - **The file is rotated or replaced.** A different inode at the same path is a
//!   different file, so the offset from the old one is meaningless. `(dev, ino)`
//!   catches that even when the replacement happens to be longer than the original,
//!   which a size check alone cannot.
//! - **The offset is past the end.** A restored cursor from before a compaction, a
//!   truncate, or a rewrite. Any file shorter than its own cursor is read from zero.
//! - **A line we cannot parse.** Not this module's problem, deliberately: the tail
//!   returns lines and the parser skips what it does not recognise. A tail that failed
//!   on one bad line would stop the stream for good, since the offset would never get
//!   past it.
//!
//! Restarting is reported rather than hidden ([`TailRead::restarted`]), because a
//! parser holding per-file state has to throw it away at the same moment the offset
//! does.

use std::fs::File;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// A single line longer than this is not a transcript record we can use; one base64
/// image attachment is megabytes on its own. Skipped rather than truncated, because a
/// half JSON object parses as nothing anyway.
pub const MAX_LINE_BYTES: usize = 2 * 1024 * 1024;

/// A file's identity, as distinct from its name.
///
/// Zero on a platform that has no inodes, which degrades this to the size check and
/// is still correct for the truncate and compaction cases.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileId {
    pub dev: u64,
    pub ino: u64,
}

impl FileId {
    /// `None` when the path is gone, which is not an error: a session whose transcript
    /// has not appeared yet and one whose transcript was deleted look the same here.
    pub fn of(path: &Path) -> Option<(Self, u64)> {
        let meta = std::fs::metadata(path).ok()?;
        Some((Self::from_meta(&meta), meta.len()))
    }

    #[cfg(unix)]
    fn from_meta(meta: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
        }
    }

    #[cfg(not(unix))]
    fn from_meta(_meta: &std::fs::Metadata) -> Self {
        Self::default()
    }
}

/// Where a tail stopped. Serialised into the durable cursor by its owner.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TailPosition {
    pub offset: u64,
    #[serde(default)]
    pub file: FileId,
}

/// What one pass of the tail found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TailRead {
    /// Complete lines only, in file order, empty ones dropped.
    pub lines: Vec<String>,
    pub position: TailPosition,
    /// True when the file was not the one the position described, so a caller holding
    /// state derived from the earlier bytes has to drop it.
    pub restarted: bool,
}

/// Read whatever is new in `path` since `from`.
///
/// A missing file yields nothing and leaves the position alone, so polling a session
/// whose CLI has not written yet is free and the first real read starts at zero.
pub fn read_new_lines(path: &Path, from: &TailPosition) -> io::Result<TailRead> {
    let Some((file_id, size)) = FileId::of(path) else {
        return Ok(TailRead {
            lines: Vec::new(),
            position: from.clone(),
            restarted: false,
        });
    };

    // Two independent reasons the stored offset cannot be trusted, and they catch
    // different things: a replacement can be longer than the original, and a truncate
    // in place keeps the inode.
    let replaced = from.file != FileId::default() && from.file != file_id;
    let shrunk = size < from.offset;
    let restarted = replaced || shrunk;
    let start = if restarted { 0 } else { from.offset };

    if size <= start {
        return Ok(TailRead {
            lines: Vec::new(),
            position: TailPosition {
                offset: start,
                file: file_id,
            },
            restarted,
        });
    }

    // `size` is the promise we read against. Bytes appended after the stat belong to
    // the next pass, whose stat will see them; reading to EOF instead would make the
    // consumed offset depend on the writer's timing.
    let want = (size - start) as usize;
    let file = File::open(path)?;
    let mut buf = vec![0u8; want];
    let read = read_exact_at(&file, &mut buf, start)?;
    buf.truncate(read);

    let Some(last_break) = buf.iter().rposition(|b| *b == b'\n') else {
        // Everything available is one unterminated line: consume nothing and wait for
        // the newline rather than handing the parser a fragment.
        return Ok(TailRead {
            lines: Vec::new(),
            position: TailPosition {
                offset: start,
                file: file_id,
            },
            restarted,
        });
    };

    let complete = &buf[..last_break];
    let lines = complete
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty() && line.len() <= MAX_LINE_BYTES)
        .map(|line| String::from_utf8_lossy(line).into_owned())
        .collect();

    Ok(TailRead {
        lines,
        position: TailPosition {
            offset: start + last_break as u64 + 1,
            file: file_id,
        },
        restarted,
    })
}

/// Positional read, so two tails on one file cannot move each other's cursor.
#[cfg(unix)]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    let mut done = 0;
    while done < buf.len() {
        match file.read_at(&mut buf[done..], offset + done as u64)? {
            0 => break,
            n => done += n,
        }
    }
    Ok(done)
}

#[cfg(not(unix))]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = file.try_clone()?;
    file.seek(SeekFrom::Start(offset))?;
    let mut done = 0;
    while done < buf.len() {
        match file.read(&mut buf[done..])? {
            0 => break,
            n => done += n,
        }
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn scratch(label: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "juancoded-tail-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn append(path: &Path, text: &str) {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("append");
        file.write_all(text.as_bytes()).expect("write");
    }

    #[test]
    fn a_missing_file_is_nothing_to_read_rather_than_an_error() {
        let read = read_new_lines(Path::new("/nope/not/here.jsonl"), &TailPosition::default())
            .expect("missing is not an error");
        assert!(read.lines.is_empty());
        assert_eq!(read.position, TailPosition::default());
        assert!(!read.restarted);
    }

    #[test]
    fn only_the_bytes_appended_since_the_last_pass_are_read() {
        let dir = scratch("grow");
        let path = dir.join("t.jsonl");
        append(&path, "one\ntwo\n");
        let first = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert_eq!(first.lines, ["one", "two"]);

        append(&path, "three\n");
        let second = read_new_lines(&path, &first.position).unwrap();
        assert_eq!(
            second.lines,
            ["three"],
            "a re-read would repeat the first two"
        );
        assert!(second.position.offset > first.position.offset);

        // Nothing new: no lines, and the offset does not move.
        let third = read_new_lines(&path, &second.position).unwrap();
        assert!(third.lines.is_empty());
        assert_eq!(third.position, second.position);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_partial_last_line_is_left_for_the_next_pass_and_arrives_whole() {
        let dir = scratch("partial");
        let path = dir.join("t.jsonl");
        append(&path, "done\n{\"half\":");
        let first = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert_eq!(first.lines, ["done"]);
        assert_eq!(
            first.position.offset, 5,
            "the fragment must stay unconsumed"
        );

        append(&path, "true}\n");
        let second = read_new_lines(&path, &first.position).unwrap();
        assert_eq!(second.lines, [r#"{"half":true}"#]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_file_with_no_newline_at_all_consumes_nothing() {
        let dir = scratch("nonewline");
        let path = dir.join("t.jsonl");
        append(&path, "no terminator yet");
        let read = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert!(read.lines.is_empty());
        assert_eq!(read.position.offset, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_file_replaced_at_the_same_path_restarts_even_when_it_is_longer() {
        let dir = scratch("rotate");
        let path = dir.join("t.jsonl");
        append(&path, "old\n");
        let first = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert_eq!(first.lines, ["old"]);

        // Rotation: the old file moves aside and a NEW inode takes the name. It is
        // longer than the old one, so a size check would call this "nothing new".
        std::fs::rename(&path, dir.join("t.jsonl.1")).expect("rotate");
        append(&path, "fresh\nlines\nhere\n");
        let second = read_new_lines(&path, &first.position).unwrap();
        assert!(second.restarted, "a new inode is a new file");
        assert_eq!(second.lines, ["fresh", "lines", "here"]);
        assert_ne!(second.position.file, first.position.file);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_offset_past_the_end_after_a_restore_rereads_from_zero() {
        let dir = scratch("past-end");
        let path = dir.join("t.jsonl");
        append(&path, "a\nb\n");
        let (file, _) = FileId::of(&path).unwrap();
        // What a cursor restored from before a compaction looks like: same file,
        // offset beyond what is now there.
        let stale = TailPosition {
            offset: 9_000,
            file,
        };
        let read = read_new_lines(&path, &stale).unwrap();
        assert!(read.restarted);
        assert_eq!(read.lines, ["a", "b"]);
        assert_eq!(read.position.offset, 4);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_truncate_in_place_keeps_the_inode_and_still_restarts() {
        let dir = scratch("truncate");
        let path = dir.join("t.jsonl");
        append(&path, "one\ntwo\nthree\n");
        let first = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert_eq!(first.lines.len(), 3);

        std::fs::write(&path, "small\n").expect("truncate in place");
        let second = read_new_lines(&path, &first.position).unwrap();
        assert!(second.restarted);
        assert_eq!(second.lines, ["small"]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn bytes_appended_after_the_stat_belong_to_the_next_pass() {
        let dir = scratch("concurrent");
        let path = dir.join("t.jsonl");
        append(&path, "first\n");
        let first = read_new_lines(&path, &TailPosition::default()).unwrap();
        // Stand in for "the writer got in between": the second pass must pick up
        // exactly the bytes the first one did not consume, with nothing repeated.
        append(&path, "second\nthird\n");
        let second = read_new_lines(&path, &first.position).unwrap();
        assert_eq!(second.lines, ["second", "third"]);
        let (_, size) = FileId::of(&path).unwrap();
        assert_eq!(second.position.offset, size);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_line_too_big_to_be_a_record_is_skipped_and_the_rest_still_arrive() {
        let dir = scratch("huge");
        let path = dir.join("t.jsonl");
        append(&path, "before\n");
        append(&path, &"x".repeat(MAX_LINE_BYTES + 1));
        append(&path, "\nafter\n");
        let read = read_new_lines(&path, &TailPosition::default()).unwrap();
        assert_eq!(read.lines, ["before", "after"]);
        std::fs::remove_dir_all(&dir).ok();
    }
}
