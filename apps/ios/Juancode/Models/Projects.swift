import Foundation
import JuancodeWire

/// Projects list shape: agent sessions grouped by the project they were started in.
struct ProjectGroup: Identifiable {
    var id: String { path }
    var path: String
    var name: String { (path as NSString).lastPathComponent }
    var sessions: [SessionMeta]

    /// `recentOnly` drops sessions untouched for two weeks (the default view; the rest are noise).
    static func group(_ sessions: [SessionMeta], recentOnly: Bool = false) -> [ProjectGroup] {
        let cutoff = recentOnly ? Int(Date().timeIntervalSince1970 * 1000) - 14 * 86_400_000 : Int.min
        let live = sessions.filter { $0.kind == .agent && !$0.archived && $0.updatedAt >= cutoff }
        return Dictionary(grouping: live, by: \.projectPath)
            .map { ProjectGroup(path: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.sessions.first?.updatedAt ?? 0) > ($1.sessions.first?.updatedAt ?? 0) }
    }
}

extension SessionMeta {
    /// The repo this session's checkout belongs to: a `<repo>-worktrees/<slot>` dir maps back to
    /// `<repo>`, so slots nest under their project as on the Mac (`projectCwd` in JuancodeCore,
    /// which the phone does not link). Any other path is its own project.
    var projectPath: String {
        let parent = (cwd as NSString).deletingLastPathComponent
        let name = (parent as NSString).lastPathComponent
        guard name.hasSuffix("-worktrees"), name.count > "-worktrees".count else { return cwd }
        return ((parent as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(String(name.dropLast("-worktrees".count)))
    }
}
