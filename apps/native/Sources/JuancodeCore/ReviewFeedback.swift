import Foundation

/// Compose staged inline diff comments into a single, deterministic review-feedback
/// prompt for the agent (juancode-ck4) — the "Annotate AI Diffs" loop that turns the
/// Changes panel into a review surface. Each comment becomes a numbered
/// `<file>:<line> — <comment>` entry with the annotated diff line (its +/- marker
/// intact) quoted beneath it, so the agent sees exactly which line each note lands on.
/// Comments staged against a commit diff (juancode-5u2) are grouped under an
/// `On commit <sha> – <subject>:` header; numbering runs continuously across groups.
///
/// Pure and SwiftUI-free so it is unit-testable without a view or a live session; the
/// quote capture and the steer-vs-submit delivery live in the app/services layer.
/// Returns "" when there are no non-empty comments.
public func composeReviewFeedback(_ comments: [DiffComment]) -> String {
    let usable = comments.filter {
        !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !usable.isEmpty else { return "" }

    // Group by the commit each comment points at (nil = working tree), keeping
    // first-appearance order so the prompt reads in the order the user staged.
    var groupOrder: [String?] = []
    var groups: [String?: [DiffComment]] = [:]
    for c in usable {
        if groups[c.commitSha] == nil { groupOrder.append(c.commitSha) }
        groups[c.commitSha, default: []].append(c)
    }

    var lines: [String] = ["Review feedback on your changes:"]
    var n = 0
    for sha in groupOrder {
        // Working-tree comments stay unlabeled — the header line already says
        // "your changes"; only commit groups get an explicit pointer.
        if let sha {
            let subject = groups[sha]?.first?.commitSubject
            let label = subject.map { "\(sha.prefix(7)) – \($0)" } ?? String(sha.prefix(7))
            lines.append("On commit \(label):")
        }
        for c in groups[sha] ?? [] {
            n += 1
            let bodyLines = c.body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            lines.append("\(n). \(reviewLocationLabel(c)) — \(bodyLines.first ?? "")")
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
