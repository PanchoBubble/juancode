import Foundation

/// Pure grouping/sorting logic for the native Issues panel (juancode-9s0). Kept
/// in JuancodeCore (SwiftUI-free) so it is unit-testable without a view layer.
///
/// The panel visualizes a folder's bd issues richer than the sidebar popover:
/// open work is split into actionability sections (Ready / Blocked / Other) and
/// closed work is collapsed into its own section, each sorted by priority then id.

extension BeadsIssue {
    /// Whether this issue is closed (not actionable to "work on").
    public var isClosed: Bool { status == "closed" }
}

/// The actionability buckets the panel groups open issues into. `rawValue`
/// doubles as the deterministic ordering (ready first, then blocked, then the
/// rest), and `closed` always sorts last.
public enum BeadsSection: Int, CaseIterable, Sendable {
    case ready = 0
    case blocked = 1
    case other = 2
    case closed = 3

    /// Section header label shown in the panel.
    public var title: String {
        switch self {
        case .ready: return "Ready"
        case .blocked: return "Blocked"
        case .other: return "In progress / Open"
        case .closed: return "Closed"
        }
    }

    /// Which section an issue belongs to. Ready beats blocked when (rarely) both
    /// flags are set, so an actionable issue surfaces at the top.
    public static func of(_ issue: BeadsIssue) -> BeadsSection {
        if issue.isClosed { return .closed }
        if issue.ready { return .ready }
        if issue.blocked { return .blocked }
        return .other
    }
}

/// One section of the panel: its kind and the issues in it (already sorted).
public struct BeadsGroup: Sendable, Equatable {
    public var section: BeadsSection
    public var issues: [BeadsIssue]

    public init(section: BeadsSection, issues: [BeadsIssue]) {
        self.section = section
        self.issues = issues
    }
}

public enum BeadsGrouping {
    /// Order two issues within a section: lower priority number first (p0 is most
    /// urgent), then by id for a stable, deterministic listing.
    public static func sort(_ a: BeadsIssue, _ b: BeadsIssue) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        return a.id < b.id
    }

    /// Group issues into ordered sections, each internally sorted by priority then
    /// id. `includeClosed: false` (the default) drops closed issues entirely — the
    /// panel's common case. Empty sections are omitted.
    public static func grouped(_ issues: [BeadsIssue], includeClosed: Bool = false) -> [BeadsGroup] {
        var buckets: [BeadsSection: [BeadsIssue]] = [:]
        for issue in issues {
            let section = BeadsSection.of(issue)
            if section == .closed && !includeClosed { continue }
            buckets[section, default: []].append(issue)
        }
        return BeadsSection.allCases.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            return BeadsGroup(section: section, issues: items.sorted(by: sort))
        }
    }
}
