import Foundation

/// Pure naming helpers for fanning one opening prompt across N parallel sessions,
/// each in its own fresh git worktree (the NewSessionView "compare N agents" flow).
/// Split out from the UI/`AppModel` so the branch-suffix + group-title generation —
/// the part that has to stay collision-free and readable — is unit-testable without
/// spawning ptys or touching git.
public enum FanOut {
    /// Upper bound on parallel agents in one fan-out (matches the NewSessionView
    /// stepper). Kept small: five isolated worktrees is already a lot of machines.
    public static let maxAgents = 5

    /// Clamp a requested agent count into the supported `1...maxAgents` range.
    public static func clampCount(_ n: Int) -> Int { min(max(n, 1), maxAgents) }

    /// Variant letters for an N-way fan-out: `["a", "b", "c", …]`. These suffix both
    /// the worktree/branch name and the session title so a group reads as one family
    /// (`<stem>-a`, `<stem>-b`). `count` is clamped to `1...maxAgents`.
    public static func letters(count: Int) -> [String] {
        (0..<clampCount(count)).map { String(UnicodeScalar(UInt8(97 + $0))) } // 97 == "a"
    }

    /// Worktree (and thus `juancode/<name>` branch) name for one variant of a group:
    /// `<stem>-<letter>`. The shared `stem` (a short random token) keeps every
    /// variant's branch collision-free across repeated fan-outs while grouping them.
    public static func worktreeName(stem: String, letter: String) -> String {
        "\(stem)-\(letter)"
    }

    /// A short, human-friendly stem derived from the opening prompt, used for the
    /// group's session titles (the branch uses a random stem for collision-safety;
    /// this one is for readability). Takes the first non-empty line, collapses
    /// whitespace, and trims to `maxLen`. Returns "" for an all-whitespace prompt.
    public static func titleStem(for prompt: String, maxLen: Int = 32) -> String {
        let firstLine = prompt
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return "" }
        let collapsed = String(firstLine)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maxLen)).trimmingCharacters(in: .whitespaces)
    }

    /// Session title for one variant of a group: `"<stem> · <letter>"`, or just the
    /// upper-cased letter when no stem is available (blank prompt). Pinned onto the
    /// session so the group stays recognizable even though every variant runs the
    /// same prompt (CLI-derived titles would be near-identical).
    public static func groupTitle(stem: String, letter: String) -> String {
        let s = stem.trimmingCharacters(in: .whitespaces)
        let tag = letter.uppercased()
        return s.isEmpty ? tag : "\(s) · \(tag)"
    }
}
