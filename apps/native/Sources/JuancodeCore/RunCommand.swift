import Foundation

/// A project's run command: a shell line the user saves once per project (say
/// `make vroom`) and starts from the play button on the project header or on a
/// session. It is typed into a fresh shell in the bottom terminal panel, so shell
/// functions and aliases from the user's rc files work as they do in a terminal.
///
/// Placeholders are filled from the checkout the command runs in:
///
///   {worktree}  absolute path of that checkout (the main one, or the session's worktree)
///   {branch}    its current branch, empty on a detached HEAD
///   {name}      the checkout's folder name (`slot-01`, or the repo's own name)
///   {project}   the project's main checkout, the same for every worktree
///
/// A value is single-quoted only when the shell would split or expand it, so the
/// common case reads in the terminal exactly as typed.
public enum RunCommand {
    /// What a placeholder can be filled from.
    public struct Context: Equatable, Sendable {
        public var worktree: String
        public var branch: String?
        public var project: String

        public init(worktree: String, branch: String?, project: String) {
            self.worktree = worktree
            self.branch = branch
            self.project = project
        }

        public var name: String { URL(fileURLWithPath: worktree).lastPathComponent }
    }

    /// The placeholders, in the order the settings UI lists them, with what each holds.
    public static let placeholders: [(token: String, help: String)] = [
        ("{worktree}", "path of the checkout it runs in"),
        ("{branch}", "that checkout's branch"),
        ("{name}", "that checkout's folder name"),
        ("{project}", "the project's main checkout"),
    ]

    /// `template` with every known placeholder replaced. Unknown `{…}` text is left
    /// alone, so shell brace expansion like `{a,b}` survives.
    public static func expand(_ template: String, _ context: Context) -> String {
        let values: [String: String] = [
            "{worktree}": context.worktree,
            "{branch}": context.branch ?? "",
            "{name}": context.name,
            "{project}": context.project,
        ]
        var out = template
        for (token, value) in values {
            out = out.replacingOccurrences(of: token, with: shellQuoted(value))
        }
        return out
    }

    /// The branch checked out at `checkout`, read straight from git's HEAD file (a
    /// worktree's `.git` is a file pointing at its own git dir). Nil on a detached
    /// HEAD or anything unreadable. For when the app has no git state for that
    /// folder yet, without blocking on a `git` process.
    public static func currentBranch(at checkout: String) -> String? {
        let dotGit = URL(fileURLWithPath: checkout).appendingPathComponent(".git")
        var gitDir = dotGit
        if let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
           pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: checkout, isDirectory: true))
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("ref: refs/heads/") else { return nil }
        return String(ref.dropFirst("ref: refs/heads/".count))
    }

    /// `value` as one shell word: unchanged when it is plainly safe, else wrapped in
    /// single quotes with any embedded quote escaped.
    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@%+=,")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
