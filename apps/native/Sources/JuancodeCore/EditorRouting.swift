import Foundation

/// How to point the user's editor at a file and line, for a fresh spawn (argv) and
/// for one that is already running (keystrokes into its pty).
///
/// Keyed off the editor's program name alone. Resolving the binary (`resolveBin`)
/// can shell out to a login shell, and nothing here needs more than the name.
public enum EditorRouting {
    /// Editors known to read `+N` as "start on line N". Anything else gets no line
    /// rather than a `+N` it would open as a file of that name. Mirrors the daemon's
    /// `LINE_ARG_EDITORS` (ephemeral.rs).
    static let lineArgEditors: Set<String> = [
        "vi", "vim", "nvim", "view", "gvim", "mvim", "nano", "emacs", "micro", "kak",
    ]

    /// Editors whose command line takes `:drop`, so a running one can be retargeted.
    static let dropEditors: Set<String> = ["vi", "vim", "nvim", "view", "gvim", "mvim"]

    /// `file` resolved against `root` as an absolute path, or nil when it lands
    /// outside it. Lexical (`standardizedFileURL`), like the daemon's `confine`.
    public static func confined(_ file: String, to root: String) -> String? {
        let root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let full = URL(fileURLWithPath: file, relativeTo: root).standardizedFileURL
        guard full.path == root.path || full.path.hasPrefix(root.path + "/") else { return nil }
        return full.path
    }

    /// The program name of an editor command (`"nvim -u NONE"` → `nvim`,
    /// `/opt/homebrew/bin/nvim` → `nvim`).
    public static func programName(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    /// The `+N` argument to put before the file, when `command` reads one.
    public static func lineArg(command: String, line: Int?) -> String? {
        guard let line, line > 0, lineArgEditors.contains(programName(command)) else { return nil }
        return "+\(line)"
    }

    /// Whether a running `command` can be sent to another file with `retargetKeys`.
    public static func canRetarget(command: String) -> Bool {
        dropEditors.contains(programName(command))
    }

    /// Keystrokes that make a running vim-family editor show `path` (absolute), at
    /// `line` when given: Ctrl-\ Ctrl-N reaches Normal mode from any mode (insert,
    /// visual, the command line, a `:terminal`), then `:drop` switches to the file's
    /// window if it has one and edits it otherwise. nil for a path the command line
    /// cannot carry.
    public static func retargetKeys(path: String, line: Int?) -> String? {
        guard path.hasPrefix("/"), !path.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        let plus = (line ?? 0) > 0 ? "+\(line!) " : ""
        return "\u{1c}\u{0e}:drop \(plus)\(fnameescape(path))\r"
    }

    /// Vim's `fnameescape()`: backslash every character the command line would
    /// otherwise read as a separator, wildcard or special name.
    static func fnameescape(_ path: String) -> String {
        let special: Set<Character> = [" ", "\t", "*", "?", "[", "{", "`", "$", "\\", "%", "#", "'", "\"", "|", "!", "<"]
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
