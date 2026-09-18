//! The named control keys a client may send instead of literal text (juancode-uigs).
//!
//! Mirror of `apps/native/Sources/JuancodeServer/NamedKey.swift` — same vocabulary,
//! same bytes, same aliases. Two cores serve the same clients, so a key that resolved
//! differently here would make the phone's Escape button depend on which core happened
//! to be running.
//!
//! Every remote input path before this went through bracketed paste (`ESC[200~` …
//! `ESC[201~`), which is what makes text LITERAL: a CLI reading a paste keeps the
//! bytes and never interprets them as keystrokes. So from Telegram or the phone there
//! was no way to send Esc, Ctrl-C or an arrow — no way to interrupt a runaway agent,
//! and no way to answer a prompt driven by arrows + Enter, which is what claude's own
//! permission prompts are.
//!
//! The table is the SERVER's, not the client's: a sidecar spelling `\x1b[A` itself
//! would be a second definition of the protocol, drifting the first time one of them
//! learned a key.

/// Arrows are the NORMAL-mode (CSI) forms, `ESC [ A` … `ESC [ D`, not the
/// application-cursor (`ESC O A`) ones: a client cannot know which mode the pty is in,
/// and both prompt TUIs here accept CSI either way.
const NAMED: &[(&str, &[u8])] = &[
    ("enter", &[0x0D]),
    ("escape", &[0x1B]),
    ("tab", &[0x09]),
    ("backspace", &[0x7F]),
    ("space", &[0x20]),
    ("up", &[0x1B, 0x5B, 0x41]),
    ("down", &[0x1B, 0x5B, 0x42]),
    ("right", &[0x1B, 0x5B, 0x43]),
    ("left", &[0x1B, 0x5B, 0x44]),
];

/// Spellings that mean a canonical name. Kept tiny on purpose: every alias is one more
/// thing the other core and the sidecar have to carry.
const ALIASES: &[(&str, &str)] = &[("esc", "escape"), ("return", "enter")];

/// The bytes `name` stands for, or `None` when it is not a key this core knows.
/// Case-insensitive, and `ctrl-c` resolves wherever `C-c` is spelled.
pub fn bytes(name: &str) -> Option<Vec<u8>> {
    let mut key = name.trim().to_ascii_lowercase();
    if let Some(rest) = key.strip_prefix("ctrl-") {
        key = format!("c-{rest}");
    }
    if let Some((_, canonical)) = ALIASES.iter().find(|(alias, _)| *alias == key) {
        key = (*canonical).to_string();
    }
    if let Some((_, bytes)) = NAMED.iter().find(|(named, _)| *named == key) {
        return Some(bytes.to_vec());
    }
    // C-a … C-z are 0x01 … 0x1A: the letter's position in the alphabet. Computed
    // rather than listed so the 26 cannot disagree with each other.
    let letter = key.strip_prefix("c-")?;
    let mut chars = letter.chars();
    let c = chars.next()?;
    if chars.next().is_some() || !c.is_ascii_lowercase() {
        return None;
    }
    Some(vec![c as u8 - b'a' + 1])
}

/// The canonical vocabulary, sorted — what an error message lists. Aliases are
/// deliberately not in it: they resolve, they are not the spelling anyone should learn.
pub fn names() -> Vec<String> {
    let mut out: Vec<String> = NAMED.iter().map(|(n, _)| canonical_case(n)).collect();
    out.extend((b'a'..=b'z').map(|c| format!("C-{}", c as char)));
    out.sort();
    out
}

/// Resolve a whole batch, or `Err` naming the first name that did not resolve. All or
/// nothing: a half-applied `Up, Up, Enter` answers a permission prompt on the wrong
/// row, which is worse than not answering it.
pub fn resolve(keys: &[String]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for name in keys {
        match bytes(name) {
            Some(b) => out.extend_from_slice(&b),
            None => return Err(name.clone()),
        }
    }
    Ok(out)
}

fn canonical_case(lower: &str) -> String {
    let mut chars = lower.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_named_keys_resolve_to_the_bytes_a_terminal_expects() {
        assert_eq!(bytes("Enter"), Some(vec![0x0D]));
        assert_eq!(bytes("Escape"), Some(vec![0x1B]));
        assert_eq!(bytes("Tab"), Some(vec![0x09]));
        assert_eq!(bytes("Backspace"), Some(vec![0x7F]));
        assert_eq!(bytes("Space"), Some(vec![0x20]));
        assert_eq!(bytes("Up"), Some(vec![0x1B, 0x5B, 0x41]));
        assert_eq!(bytes("Down"), Some(vec![0x1B, 0x5B, 0x42]));
        assert_eq!(bytes("Right"), Some(vec![0x1B, 0x5B, 0x43]));
        assert_eq!(bytes("Left"), Some(vec![0x1B, 0x5B, 0x44]));
    }

    #[test]
    fn every_control_letter_is_its_position_in_the_alphabet() {
        assert_eq!(bytes("C-a"), Some(vec![0x01]));
        assert_eq!(bytes("C-c"), Some(vec![0x03]));
        assert_eq!(bytes("C-d"), Some(vec![0x04]));
        assert_eq!(bytes("C-z"), Some(vec![0x1A]));
    }

    #[test]
    fn spelling_is_forgiving_because_a_phone_keyboard_is_not() {
        assert_eq!(bytes("ESCAPE"), bytes("escape"));
        assert_eq!(bytes("esc"), bytes("Escape"));
        assert_eq!(bytes("return"), bytes("Enter"));
        assert_eq!(bytes("ctrl-c"), bytes("C-c"));
        assert_eq!(bytes("  Up  "), bytes("Up"));
    }

    #[test]
    fn an_unknown_name_resolves_to_nothing_rather_than_to_its_own_text() {
        // The whole point of the vocabulary: "Excape" typed into an agent's prompt box
        // is a worse answer than an error.
        assert_eq!(bytes("Excape"), None);
        assert_eq!(bytes("C-"), None);
        assert_eq!(bytes("C-cc"), None);
        assert_eq!(bytes("C-1"), None);
        assert_eq!(bytes(""), None);
    }

    #[test]
    fn a_batch_is_all_or_nothing() {
        assert_eq!(
            resolve(&["Up".into(), "Up".into(), "Enter".into()]),
            Ok(vec![0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x41, 0x0D])
        );
        assert_eq!(
            resolve(&["Up".into(), "Nope".into(), "Enter".into()]),
            Err("Nope".to_string())
        );
    }

    #[test]
    fn the_vocabulary_is_the_whole_advertised_surface() {
        let names = names();
        assert_eq!(names.len(), 9 + 26);
        for expected in [
            "Enter",
            "Escape",
            "Tab",
            "Backspace",
            "Space",
            "Up",
            "C-a",
            "C-z",
        ] {
            assert!(names.contains(&expected.to_string()), "missing {expected}");
        }
    }
}
