import Foundation

/// Stands up the throwaway git repos the real-git tests commit into.
///
/// A fixture repo must not read the developer's global git config. Where
/// `commit.gpgsign=true` is set globally and `gpg` is not on the PATH the test
/// process inherits — the default for a headless or dispatched session — every
/// fixture commit dies with `cannot run gpg: No such file or directory`, and the
/// suite reads as a wall of failures that have nothing to do with the code under
/// test. Pinning the identity here too means the repo never reads the
/// developer's name or email either.
enum TempGitRepo {
    /// `git init` in `path`, then the repo-local config every fixture repo needs.
    ///
    /// `init.defaultBranch` is deliberately left alone: some tests read the
    /// default branch name back out and must see whatever this machine's git
    /// would produce.
    static func initialize(at path: String) throws {
        try run(["init", "-q"], in: path)
        try run(["config", "user.email", "test@example.com"], in: path)
        try run(["config", "user.name", "Test"], in: path)
        try run(["config", "commit.gpgsign", "false"], in: path)
        try run(["config", "tag.gpgsign", "false"], in: path)
    }

    /// A bare repo to push at. Nothing commits here, but it gets the same
    /// treatment so no fixture repo anywhere reads global signing config.
    static func initializeBare(at path: String) throws {
        try run(["init", "-q", "--bare"], in: path)
        try run(["config", "commit.gpgsign", "false"], in: path)
    }

    static func run(_ args: [String], in cwd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self)
            ])
        }
    }
}
