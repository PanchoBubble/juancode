import Foundation
import JuancodeWire

/// The drawer's shape: agent sessions grouped by the project they were started in.
struct ProjectGroup: Identifiable {
    var id: String { path }
    var path: String
    var name: String { (path as NSString).lastPathComponent }
    var sessions: [SessionMeta]

    static func group(_ sessions: [SessionMeta]) -> [ProjectGroup] {
        let live = sessions.filter { $0.kind == .agent && !$0.archived }
        return Dictionary(grouping: live, by: \.cwd)
            .map { ProjectGroup(path: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.sessions.first?.updatedAt ?? 0) > ($1.sessions.first?.updatedAt ?? 0) }
    }
}
