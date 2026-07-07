import Foundation

/// Pure helpers for confirming a seeded prompt is delivered into a CLI's input box
/// (see `Session.autoSubmit`). Split out from `Session` so the brittle text-matching
/// — the part most likely to drift as `claude`/`codex` change their TUI wording — is
/// unit-testable without spinning up a real pty. Mirrors
/// `apps/server/src/initialPromptDelivery.ts`.
public enum InitialPromptDelivery {
    /// A distinctive, normalized token taken from the start of `prompt`, used to
    /// find the prompt in — or confirm it has left — the input box. We take the
    /// first non-empty line (the box reflows long/multi-line text, so only the
    /// first rendered row is reliably contiguous) and keep a short prefix so the
    /// signature stays within a single wrapped box row.
    ///
    /// Returns "" for an all-whitespace prompt; an empty signature never matches
    /// (see `region(_:contains:)`), so callers treat that as "nothing to verify".
    public static func signature(for prompt: String, maxLen: Int = 24) -> String {
        let firstLine = prompt
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return "" }
        let normalized = normalize(String(firstLine))
        return String(normalized.prefix(maxLen))
    }

    /// True if `signature` appears in `screenRegion`. Both sides are whitespace-
    /// collapsed and lowercased first, so the box's padding/borders and the
    /// prompt's own spacing don't defeat the match. An empty signature never
    /// matches (there's nothing distinctive to look for).
    public static func region(_ screenRegion: String, contains signature: String) -> Bool {
        let sig = normalize(signature)
        guard !sig.isEmpty else { return false }
        return normalize(screenRegion).contains(sig)
    }

    /// Claude collapses a large or multi-line bracketed paste into a placeholder
    /// chip (`[Pasted text #1 +29 lines]`) instead of echoing the literal text, so
    /// the prompt `signature` never appears on screen even though the paste is
    /// sitting in the input box. Detect that chip so delivery can treat the paste as
    /// landed (and, on submit, wait for the chip itself to clear). See
    /// `Session.autoSubmit`.
    public static func regionShowsCollapsedPaste(_ screenRegion: String) -> Bool {
        normalize(screenRegion).contains("pasted text")
    }

    /// Lowercase and collapse every run of whitespace (incl. newlines) to a single
    /// space, trimming the ends — the canonical form both sides are compared in.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
