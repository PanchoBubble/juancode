import Foundation

/// Pure, SwiftUI-free logic backing the ChangesPanel's keyboard-driven review flow:
/// per-file viewed-state (persisted so only *changed* files re-appear as unviewed),
/// clamped file/hunk navigation, and collapse-by-default eligibility for generated
/// or oversized diffs. No git, no AppKit — kept here so it's unit-testable and shared
/// between the view and any future surface.

// MARK: - Stable per-file hashing

/// A deterministic 64-bit FNV-1a hash of a string, hex-encoded. Unlike Swift's
/// `Hasher` (seeded per-process), this is stable across launches, so it can key
/// persisted viewed-state on a file's content.
public func stableHash(_ s: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01b3
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* prime
    }
    return String(hash, radix: 16)
}

/// A stable fingerprint of one file's diff — its path, status, counts, and body. Two
/// loads of the same change produce the same hash; any edit to the file's diff shifts
/// it, which is exactly "this file changed since I last looked".
public func fileDiffHash(_ file: DiffFile) -> String {
    stableHash("\(file.status.rawValue):\(file.additions):\(file.deletions):\(file.path):\(file.diff)")
}

// MARK: - Viewed-state (persisted per diff-hash)

/// Whether a file counts as "viewed": it was marked viewed while showing exactly the
/// content it shows now. A file whose diff has since changed reads as unviewed again.
public func isFileViewed(_ file: DiffFile, viewed: [String: String]) -> Bool {
    viewed[file.path] == fileDiffHash(file)
}

/// Record a file as viewed at its current content hash.
public func markingViewed(_ file: DiffFile, in viewed: [String: String]) -> [String: String] {
    var out = viewed
    out[file.path] = fileDiffHash(file)
    return out
}

/// Drop viewed entries for paths no longer in the diff, so the store doesn't grow
/// unbounded across many reviews.
public func prunedViewed(_ viewed: [String: String], keeping files: [DiffFile]) -> [String: String] {
    let live = Set(files.map(\.path))
    return viewed.filter { live.contains($0.key) }
}

/// How many of `files` are currently viewed — drives the "n of N viewed" progress.
public func viewedCount(_ files: [DiffFile], viewed: [String: String]) -> Int {
    files.reduce(0) { $0 + (isFileViewed($1, viewed: viewed) ? 1 : 0) }
}

// MARK: - Keyboard navigation index math

/// Step a list cursor by `delta`, clamped into `[0, count - 1]`. A nil `current`
/// starts from the first (delta ≥ 0) or last (delta < 0) row. Returns nil for an
/// empty list. Kept pure so j/k file nav and n/p hunk nav share one tested rule.
public func steppedIndex(current: Int?, count: Int, delta: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return delta >= 0 ? 0 : count - 1 }
    let next = current + delta
    return Swift.min(Swift.max(next, 0), count - 1)
}

/// The number of hunks in a file's unified diff — a cheap `@@`-header count that
/// matches `parseUnifiedDiff`'s hunk count without a full parse. Used by hunk nav to
/// bound n/p without the view needing the parsed model.
public func hunkCount(inDiff diff: String) -> Int {
    guard !diff.isEmpty else { return 0 }
    return diff.split(separator: "\n", omittingEmptySubsequences: false)
        .reduce(0) { $0 + ($1.hasPrefix("@@") ? 1 : 0) }
}

// MARK: - Collapse-by-default eligibility

/// Threshold above which a text diff is treated as oversized and collapsed by default.
public let defaultLargeDiffLineThreshold = 400

/// Whether a path looks machine-generated — lockfiles, minified bundles, source maps,
/// and snapshot dumps — the kind of diff you almost never read line-by-line.
public func isGeneratedPath(_ path: String) -> Bool {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    let lower = name.lowercased()
    let lockfiles: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "npm-shrinkwrap.json",
        "cargo.lock", "package.resolved", "go.sum", "composer.lock",
        "gemfile.lock", "poetry.lock", "pipfile.lock", "bun.lockb", "flake.lock",
    ]
    if lockfiles.contains(lower) { return true }
    let generatedSuffixes = [".min.js", ".min.css", ".map", ".snap", ".pb.go", ".g.dart"]
    return generatedSuffixes.contains { lower.hasSuffix($0) }
}

/// Whether a file should open collapsed with only a summary row: binary, already
/// truncated, generated, or larger than `threshold` changed lines. Expand-on-demand
/// still works; this only sets the default and drives which files "expand all" skips.
public func isCollapsedByDefault(_ file: DiffFile, threshold: Int = defaultLargeDiffLineThreshold) -> Bool {
    if file.binary || file.truncated { return true }
    if isGeneratedPath(file.path) { return true }
    return file.additions + file.deletions > threshold
}

/// A one-line reason a collapsed file is worth skipping, shown in its summary row, or
/// nil for a file that's collapsed only by user choice.
public func collapseSummary(for file: DiffFile, threshold: Int = defaultLargeDiffLineThreshold) -> String? {
    if file.binary { return "Binary file" }
    if file.truncated { return "Diff too large to display" }
    if isGeneratedPath(file.path) { return "Generated file · \(file.additions + file.deletions) changes" }
    let total = file.additions + file.deletions
    if total > threshold { return "Large diff · \(total) changes" }
    return nil
}
