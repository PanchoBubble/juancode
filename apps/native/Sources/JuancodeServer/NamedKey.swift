import Foundation

/// The named control keys a client may send instead of literal text (juancode-uigs).
///
/// Every remote input path before this went through bracketed paste — `ESC[200~` …
/// `ESC[201~` — which is exactly what makes text LITERAL: a CLI reading a paste keeps
/// the bytes and never interprets them as keystrokes. So from Telegram or the phone
/// console there was no way to send Esc, Ctrl-C or an arrow, and the two things that
/// cost were the two that matter remotely: you could not interrupt a runaway agent,
/// and you could not answer a prompt driven by arrows + Enter, which is what claude's
/// own permission prompts are. A session stopped on a permission prompt was
/// unreachable from the phone.
///
/// The table lives here, server-side, and NOT in the clients: a sidecar that spelled
/// `\u{1b}[A` itself would be a second definition of the protocol, drifting the first
/// time one of them learned a key. A client sends the NAME; the server resolves it.
///
/// Resolution is case-insensitive, and accepts `ctrl-c` wherever `C-c` is spelled,
/// because a phone keyboard and a person typing a command do not agree on either.
/// An unknown name resolves to nil, and the wire path refuses the whole frame rather
/// than falling back to typing the name as text — silently sending "Excape" into an
/// agent's prompt box is worse than an error.
public enum NamedKey {
    /// Arrows are the NORMAL-mode (CSI) forms, `ESC [ A` … `ESC [ D`, not the
    /// application-cursor (`ESC O A`) ones. Both real prompt TUIs here — claude's ink
    /// renderer and codex's — accept the CSI forms whichever mode they are in, and a
    /// client has no way to know which mode the pty is in right now, so guessing the
    /// application form would be the one that breaks in the common case.
    private static let table: [String: [UInt8]] = {
        var t: [String: [UInt8]] = [
            "enter": [0x0D],
            "escape": [0x1B],
            "tab": [0x09],
            "backspace": [0x7F],
            "space": [0x20],
            "up": [0x1B, 0x5B, 0x41],
            "down": [0x1B, 0x5B, 0x42],
            "right": [0x1B, 0x5B, 0x43],
            "left": [0x1B, 0x5B, 0x44],
        ]
        // C-a … C-z are 0x01 … 0x1A: the letter's position in the alphabet. Generated
        // rather than listed so the 26 cannot disagree with each other.
        for (i, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            t["c-\(letter)"] = [UInt8(1 + i)]
        }
        return t
    }()

    /// Spellings that mean a canonical name. Kept tiny on purpose: every alias is one
    /// more thing the TS mirror has to carry, and the mirror test compares them.
    private static let aliases: [String: String] = ["esc": "escape", "return": "enter"]

    /// The canonical vocabulary, sorted — what an error message lists and what the
    /// sidecar's mirror test compares itself against. Aliases are deliberately not in
    /// it: they resolve, they are not the spelling anyone should learn.
    public static var names: [String] {
        table.keys.sorted().map(canonicalCase)
    }

    /// The bytes `name` stands for, or nil when it is not a key this server knows.
    public static func bytes(for name: String) -> [UInt8]? {
        var key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasPrefix("ctrl-") { key = "c-" + key.dropFirst("ctrl-".count) }
        if let canonical = aliases[key] { key = canonical }
        return table[key]
    }

    /// What resolving a batch of names came to.
    public enum Resolution: Equatable {
        case bytes([UInt8])
        /// The first name that did not resolve; the batch wrote nothing.
        case unknown(String)
    }

    /// Resolve a whole batch, all or nothing: a half-applied `Up, Up, Enter` submits
    /// the wrong menu row, which is a worse answer to a permission prompt than none.
    public static func resolve(_ keys: [String]) -> Resolution {
        var out: [UInt8] = []
        for name in keys {
            guard let resolved = bytes(for: name) else { return .unknown(name) }
            out.append(contentsOf: resolved)
        }
        return .bytes(out)
    }

    /// `c-c` → `C-c`, `escape` → `Escape`: the spelling the vocabulary is documented in.
    private static func canonicalCase(_ lower: String) -> String {
        if lower.hasPrefix("c-") { return "C-" + lower.dropFirst(2) }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
