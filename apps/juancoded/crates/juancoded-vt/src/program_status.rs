//! OSC 7501 revision 0.4. Independently implemented from the Rex specification:
//! https://www.superlogical.com/rex/docs/build/program-status
//! Metadata only: these records never authorize input or change agent readiness.
use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
    Engine,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgramStatusRecord {
    pub id: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
}
impl ProgramStatusRecord {
    pub fn completed(&self) -> bool {
        matches!(self.state.as_str(), "done" | "error")
    }
    fn rank(&self) -> u8 {
        match self.state.as_str() {
            "blocked" => 0,
            "error" => 1,
            "done" => 2,
            "working" => 3,
            _ => 4,
        }
    }
}
fn segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
}
fn text(s: &str, encoded: usize, decoded: usize) -> Option<String> {
    if s.len() > encoded {
        return None;
    }
    let bytes = STANDARD
        .decode(s)
        .or_else(|_| STANDARD_NO_PAD.decode(s))
        .ok()?;
    if bytes.len() > decoded {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    if text.chars().any(char::is_control) {
        return None;
    }
    // Disarm format characters outside the terminal grid (including bidi controls).
    Some(
        text.chars()
            .filter(|c| {
                !matches!(*c as u32,
        0xad | 0x600..=0x605 | 0x61c | 0x6dd | 0x70f | 0x890..=0x891 | 0x8e2 |
        0x180e | 0x200b..=0x200f | 0x2028..=0x202e | 0x2060..=0x206f | 0xfeff |
        0xfff9..=0xfffb | 0x110bd | 0x110cd | 0x13430..=0x13455 |
        0x1bca0..=0x1bca3 | 0x1d173..=0x1d17a | 0xe0000..=0xe007f)
            })
            .collect(),
    )
}
fn trim_blank(mut bytes: &[u8]) -> &[u8] {
    while bytes.first().is_some_and(|b| matches!(b, b' ' | b'\t')) {
        bytes = &bytes[1..];
    }
    while bytes.last().is_some_and(|b| matches!(b, b' ' | b'\t')) {
        bytes = &bytes[..bytes.len() - 1];
    }
    bytes
}
fn parse(body: &[u8]) -> Option<ProgramStatusRecord> {
    let mut fields = BTreeMap::new();
    for pair in body.split(|b| *b == b':') {
        let Some(eq) = pair.iter().position(|b| *b == b'=') else {
            continue;
        };
        let key = trim_blank(&pair[..eq]);
        if key.len() > 16 {
            return None;
        }
        let Ok(key) = std::str::from_utf8(key) else {
            continue;
        };
        let value = trim_blank(&pair[eq + 1..]);
        let Ok(value) = std::str::from_utf8(value) else {
            if key == "id" {
                return None;
            }
            continue;
        };
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        if !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b))
        {
            if key == "id" {
                return None;
            }
            continue;
        }
        // Every pair must fit limits, even when a later duplicate replaces it.
        if match key {
            "app" => value.len() > 32,
            "id" => value.len() > 128,
            "title" => value.len() > 256,
            "msg" => value.len() > 2732,
            _ => false,
        } {
            return None;
        }
        fields.insert(key, value);
    }
    let state = *fields.get("state")?;
    if !matches!(
        state,
        "idle" | "working" | "blocked" | "done" | "error" | "clear"
    ) {
        return None;
    }
    let id = fields.get("id").copied().unwrap_or("");
    if fields.contains_key("id") && (id.split('/').count() > 8 || !id.split('/').all(segment)) {
        return None;
    }
    let title = match fields.get("title") {
        Some(value) => Some(text(value, 256, 192)?),
        None => None,
    };
    let msg = match fields.get("msg") {
        Some(value) => Some(text(value, 2732, 2048)?),
        None => None,
    };
    let progress = fields
        .get("progress")
        .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|s| s.parse::<u8>().ok())
        .filter(|p| *p <= 100)
        .filter(|_| matches!(state, "working" | "blocked"));
    Some(ProgramStatusRecord {
        id: id.into(),
        state: state.into(),
        title,
        msg,
        progress,
        app: fields
            .get("app")
            .filter(|s| segment(s))
            .map(|s| (*s).into()),
        kind: fields
            .get("kind")
            .filter(|s| state == "blocked" && matches!(**s, "permission" | "question" | "auth"))
            .map(|s| (*s).into()),
    })
}
#[derive(Default)]
enum Scan {
    #[default]
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    Ignore,
    IgnoreEscape,
}
/// A bounded observer of the same byte stream as the VT parser. Never consumes or
/// rewrites grid bytes, and never scans the contents of DCS/APC/PM/SOS strings.
#[derive(Default)]
pub struct ProgramStatus {
    scan: Scan,
    payload: Vec<u8>,
    overflow: bool,
    records: Vec<ProgramStatusRecord>, // oldest update first
    reply: Option<Vec<u8>>,            // coalesce query floods; never echo report data
}
impl ProgramStatus {
    pub fn records(&self) -> Vec<ProgramStatusRecord> {
        let mut indexed: Vec<_> = self.records.iter().enumerate().collect();
        indexed.sort_by_key(|(i, r)| (r.rank(), !r.id.is_empty(), std::cmp::Reverse(*i)));
        indexed
            .into_iter()
            .map(|(_, r)| {
                let mut result = r.clone();
                let mut parent = r.id.as_str();
                while result.app.is_none() && !parent.is_empty() {
                    parent = parent.rsplit_once('/').map_or("", |(p, _)| p);
                    result.app = self
                        .records
                        .iter()
                        .find(|r| r.id == parent)
                        .and_then(|r| r.app.clone());
                }
                result
            })
            .collect()
    }
    pub fn take_reply(&mut self) -> Option<Vec<u8>> {
        self.reply.take()
    }
    pub fn exit_or_prompt(&mut self) {
        self.records.retain(ProgramStatusRecord::completed);
    }
    pub fn input(&mut self) {
        self.records.retain(|r| !r.completed());
    }
    pub fn reset(&mut self) {
        self.records.clear();
        self.reply = None;
    }
    pub fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes {
            if matches!(b, 0x18 | 0x1a) {
                self.scan = Scan::Ground;
                self.payload.clear();
                continue;
            }
            match self.scan {
                Scan::Ground => {
                    if b == 0x1b {
                        self.scan = Scan::Escape;
                    }
                }
                Scan::Escape => match b {
                    b']' => {
                        self.payload.clear();
                        self.overflow = false;
                        self.scan = Scan::Osc;
                    }
                    b'P' | b'_' | b'^' | b'X' => self.scan = Scan::Ignore,
                    b'[' => self.scan = Scan::Csi,
                    b'c' => {
                        self.reset();
                        self.scan = Scan::Ground;
                    }
                    0x1b => (),
                    0x20..=0x2f => self.scan = Scan::Csi,
                    _ => self.scan = Scan::Ground,
                },
                Scan::Csi => {
                    if b == 0x1b {
                        self.scan = Scan::Escape;
                    } else if (0x40..=0x7e).contains(&b) {
                        self.scan = Scan::Ground;
                    }
                }
                Scan::Osc => match b {
                    7 => self.finish(true),
                    0x1b => self.scan = Scan::OscEscape,
                    _ => self.push(b),
                },
                Scan::OscEscape => {
                    if b == b'\\' {
                        self.finish(false);
                    } else {
                        self.payload.clear();
                        self.scan = Scan::Escape;
                        self.feed(&[b]);
                    }
                }
                Scan::Ignore => {
                    if b == 0x1b {
                        self.scan = Scan::IgnoreEscape;
                    }
                }
                Scan::IgnoreEscape => {
                    self.scan = if b == b'\\' {
                        Scan::Ground
                    } else {
                        Scan::Ignore
                    }
                }
            }
        }
    }
    fn push(&mut self, b: u8) {
        if self.payload.len() < 4093 {
            self.payload.push(b);
        } else {
            self.overflow = true;
        }
    }
    fn finish(&mut self, bel: bool) {
        self.scan = Scan::Ground;
        if self.overflow || self.payload.len() + if bel { 3 } else { 4 } > 4096 {
            return;
        }
        if self.payload == b"133;A" || self.payload.starts_with(b"133;A;") {
            self.exit_or_prompt();
            return;
        }
        let Some(body) = self.payload.strip_prefix(b"7501;") else {
            return;
        };
        if trim_blank(body) == b"?" {
            self.reply = Some(if bel {
                b"\x1b]7501;?\x07".to_vec()
            } else {
                b"\x1b]7501;?\x1b\\".to_vec()
            });
            return;
        }
        let Some(record) = parse(body) else {
            return;
        };
        if record.state == "clear" {
            self.records.retain(|r| {
                !(record.id.is_empty()
                    || r.id == record.id
                    || r.id.starts_with(&format!("{}/", record.id)))
            });
        } else {
            self.records.retain(|r| r.id != record.id);
            if self.records.len() == 256 {
                self.records.remove(0);
            }
            self.records.push(record);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn report(s: &str) -> Vec<u8> {
        format!("\x1b]7501;{s}\x1b\\").into_bytes()
    }
    #[test]
    fn every_chunk_boundary_and_single_bytes_preserve_grid_and_titles() {
        let data = [
            b"\x1b]2;title\x07hello".as_slice(),
            &report("state=working:progress=42:msg=Y2Fmw6k"),
        ]
        .concat();
        for split in 0..=data.len() {
            let mut terminal = crate::TerminalModel::new(20, 3, 10);
            terminal.feed(&data[..split]);
            terminal.feed(&data[split..]);
            assert_eq!(terminal.title().as_deref(), Some("title"));
            assert_eq!(terminal.snapshot().text(), "hello");
            let r = terminal.program_status.records();
            assert_eq!(r[0].msg.as_deref(), Some("café"));
            assert_eq!(r[0].progress, Some(42));
        }
        let mut s = ProgramStatus::default();
        for b in &data {
            s.feed(&[*b]);
        }
        assert_eq!(s.records()[0].state, "working");
    }
    #[test]
    fn validation_is_atomic_and_progress_is_optional() {
        for bad in [
            "state=unknown",
            "state=done:msg=/w==",
            "state=done:msg=YQ=",
            "state=done:msg=YR==",
            "state=done:msg=Cg==",
            "state=done:msg=woU=",
            "state=done:id=",
            "state=done:id=a//b",
            "state=done:id=a;b",
            "state=done:id=a/b/c/d/e/f/g/h/i",
        ] {
            let mut s = ProgramStatus::default();
            s.feed(&report("state=working"));
            s.feed(&report(bad));
            assert_eq!(s.records()[0].state, "working", "{bad}");
        }
        assert_eq!(parse(b"state=done:unknown=\xff").unwrap().state, "done");
        assert!(parse(b"state=done:id=\xff").is_none());
        for p in ["-1", "+1", "101", "1.2", "99999999999", ""] {
            let r = parse(format!("state=blocked:progress={p}").as_bytes()).unwrap();
            assert_eq!(r.progress, None);
        }
        for p in ["0", "100", "001"] {
            assert!(parse(format!("state=working:progress={p}").as_bytes())
                .unwrap()
                .progress
                .is_some());
        }
        let r =
            parse(b"bad:state=idle:state=blocked:kind=auth:unknown=ok:app=not/valid:progress=20")
                .unwrap();
        assert_eq!(r.kind.as_deref(), Some("auth"));
        assert_eq!(r.app, None);
        assert_eq!(
            parse(b"state=done:kind=auth:progress=20").unwrap().kind,
            None
        );
        assert_eq!(
            parse(b" state = working :msg=YQ==").unwrap().msg.as_deref(),
            Some("a")
        );
        assert_eq!(
            parse(b"state=done:msg=YWJj4oCuZGVm")
                .unwrap()
                .msg
                .as_deref(),
            Some("abcdef")
        );
    }
    #[test]
    fn oversized_sequences_and_fields_do_not_mutate_or_grow_memory() {
        let mut s = ProgramStatus::default();
        s.feed(&report("state=idle"));
        for (key, value) in [
            ("msg", "YQ==".repeat(700)),
            ("title", "A".repeat(257)),
            ("app", "a".repeat(33)),
            ("id", "a".repeat(129)),
            ("abcdefghijklmnopq", "x".into()),
        ] {
            s.feed(&report(&format!("state=error:{key}={value}")));
            assert_eq!(s.records()[0].state, "idle");
        }
        s.feed(b"\x1b]7501;state=error:unknown=");
        s.feed(&vec![b'a'; 100_000]);
        assert!(s.payload.len() <= 4093);
        s.feed(b"\x07");
        assert_eq!(s.records()[0].state, "idle");
        s.feed(&report("state=done"));
        assert_eq!(s.records()[0].state, "done");
        // Limit applies even to an overwritten pair.
        assert!(parse(format!("state=done:app={}:app=ok", "a".repeat(33)).as_bytes()).is_none());
    }
    #[test]
    fn hierarchy_replacement_eviction_and_summary() {
        let mut s = ProgramStatus::default();
        s.feed(&report("state=working:app=root"));
        s.feed(&report("state=working:id=build:app=cargo"));
        s.feed(&report("state=blocked:id=build/test:kind=question"));
        assert_eq!(s.records()[0].app.as_deref(), Some("cargo"));
        s.feed(&report("state=done:id=build")); // replaces app, child inherits root
        assert_eq!(s.records()[0].app.as_deref(), Some("root"));
        s.feed(&report("state=clear:id=build"));
        assert_eq!(s.records().len(), 1);
        s.feed(&report("state=clear"));
        assert!(s.records().is_empty());
        for i in 0..257 {
            s.feed(&report(&format!("state=idle:id=r{i}")));
        }
        assert_eq!(s.records().len(), 256);
        assert!(!s.records().iter().any(|r| r.id == "r0"));
        s.feed(&report("state=idle"));
        assert!(s.records()[0].id.is_empty());
    }
    #[test]
    fn prompt_exit_input_and_resets_have_distinct_lifetimes() {
        let mut s = ProgramStatus::default();
        for state in ["working", "blocked", "idle", "done", "error"] {
            s.feed(&report(&format!("state={state}:id={state}")));
        }
        s.feed(b"\x1b[!p\x1b[?1049h");
        assert_eq!(s.records().len(), 5);
        s.feed(b"\x1b]133;A\x07");
        assert_eq!(s.records().len(), 2);
        s.feed(&report("state=working"));
        s.exit_or_prompt();
        assert_eq!(s.records().len(), 2);
        s.input();
        assert!(s.records().is_empty());
        s.feed(&report("state=blocked"));
        s.input();
        assert_eq!(s.records().len(), 1);
        s.feed(b"\x1bc");
        assert!(s.records().is_empty());
    }
    #[test]
    fn only_exact_queries_reply_and_string_contents_are_not_commands() {
        let mut s = ProgramStatus::default();
        for end in [b"\x07".as_slice(), b"\x1b\\"] {
            let q = [b"\x1b]7501;?".as_slice(), end].concat();
            for b in &q {
                s.feed(&[*b]);
            }
            assert_eq!(s.take_reply(), Some(q));
            assert_eq!(s.take_reply(), None);
        }
        for data in [
            b"\x1b]7501;?\n\x07".as_slice(),
            b"\x1b]7501;?:states=idle\x07".as_slice(),
            b"\x1b]7501;state=done:msg=Pw==\x07",
            b"\x1bP\x1b]7501;?\x07\x1b\\",
            b"\x1b_\x1b]7501;?\x07\x1b\\",
        ] {
            s.feed(data);
            assert_eq!(s.take_reply(), None);
        }
        s.feed(b"\x1b]7501;state=error\x18\x07");
        assert_eq!(s.records()[0].state, "done");
        s.feed(b"\x1b]2;\x1bc");
        assert!(s.records().is_empty());
    }
}
