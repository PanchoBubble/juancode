import Foundation

/// Compose staged inline diff comments into a single, deterministic review-feedback
/// prompt for the agent (juancode-ck4) — the "Annotate AI Diffs" loop that turns the
/// Changes panel into a review surface. Each comment becomes a numbered
/// `<file>:<line> — <comment>` entry with the annotated diff line (its +/- marker
/// intact) quoted beneath it, so the agent sees exactly which line each note lands on.
///
/// Pure and SwiftUI-free so it is unit-testable without a view or a live session; the
/// quote capture and the steer-vs-submit delivery live in the app/services layer.
/// Returns "" when there are no non-empty comments.
public func composeReviewFeedback(_ comments: [DiffComment]) -> String {
    let usable = comments.filter {
        !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !usable.isEmpty else { return "" }

    var lines: [String] = ["Review feedback on your changes:"]
    for (i, c) in usable.enumerated() {
        let bodyLines = c.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.append("\(i + 1). \(reviewLocationLabel(c)) — \(bodyLines.first ?? "")")
        // Continuation lines of a multi-line comment sit under the entry.
        for cont in bodyLines.dropFirst() { lines.append("   \(cont)") }
        // Quote the highlighted diff line(s) verbatim (markers + code indentation
        // preserved); only the surrounding newlines are trimmed.
        if let quote = c.quote?.trimmingCharacters(in: .newlines), !quote.isEmpty {
            for q in quote.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("   > \(q)")
            }
        }
    }
    lines.append("Please address each point.")
    return lines.joined(separator: "\n")
}

/// `<file>:<line>` for a single line, `<file>:<lo>-<hi>` for a range, suffixed
/// ` (old)` when the comment anchors to the pre-change (old) side.
public func reviewLocationLabel(_ c: DiffComment) -> String {
    let linePart = c.line == c.endLine ? "\(c.line)" : "\(c.line)-\(c.endLine)"
    let side = c.side == .old ? " (old)" : ""
    return "\(c.file):\(linePart)\(side)"
}
