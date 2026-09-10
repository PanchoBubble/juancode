import Foundation
import JuancodeCore

/// Read side of the sidecar's dispatch registry (`oracle-dispatches.json`).
///
/// The native app owns the *result* truth (`dispatch-results.jsonl`); the sidecar
/// owns the *request* side — the prompt, the provider, the originating Telegram
/// chat — and records every dispatch it created in this file (see
/// `apps/oracle-mcp/src/dispatch-registry.ts`). The dispatch-chain graph
/// (juancode-wn64) needs the prompt to tell which ticket a session was started
/// for, so it reads the file. Read-only and tolerant of every failure mode: a
/// missing file, a half-written one, a record whose shape the sidecar has since
/// changed. Nothing here writes — the sidecar is the only writer.
public struct OracleDispatchRecord: Codable, Sendable, Equatable {
    public var dispatchId: String
    public var project: String
    public var prompt: String
    public var provider: String
    public var worktree: Bool
    /// "started" / "queued" / "rejected".
    public var outcome: String
    public var sessionId: String?
    public var error: String?
    /// ms since epoch.
    public var at: Int

    public init(dispatchId: String, project: String, prompt: String, provider: String,
                worktree: Bool, outcome: String, sessionId: String?, error: String?, at: Int) {
        self.dispatchId = dispatchId; self.project = project; self.prompt = prompt
        self.provider = provider; self.worktree = worktree; self.outcome = outcome
        self.sessionId = sessionId; self.error = error; self.at = at
    }

    /// Decoded leniently: the fields the graph doesn't need are optional, so a
    /// record written by a newer (or older) sidecar still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dispatchId = try c.decode(String.self, forKey: .dispatchId)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        worktree = try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? "started"
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        at = try c.decodeIfPresent(Int.self, forKey: .at) ?? 0
    }

    /// The graph's reduced view of this record.
    public var graphInput: GraphDispatchInput {
        GraphDispatchInput(dispatchId: dispatchId, project: project, prompt: prompt,
                           provider: provider, sessionId: sessionId, outcome: outcome, at: at)
    }
}

/// `~/.juancode/oracle/oracle-dispatches.json` (honouring `JUANCODE_ORACLE_DIR`).
public var oracleDispatchRegistryFile: String {
    (OraclePaths.controlDir as NSString).appendingPathComponent("oracle-dispatches.json")
}

/// Every dispatch the sidecar recorded, newest first. Empty when the file is
/// absent or unreadable — the panel then just shows no dispatch column.
public func readOracleDispatchRegistry(limit: Int = 200) -> [OracleDispatchRecord] {
    let url = URL(fileURLWithPath: oracleDispatchRegistryFile)
    guard let data = try? Data(contentsOf: url) else { return [] }
    // The whole file is one JSON array; a per-element decode keeps one bad record
    // from losing the rest.
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
    var out: [OracleDispatchRecord] = []
    for element in raw.reversed() {
        guard out.count < limit else { break }
        guard let object = try? JSONSerialization.data(withJSONObject: element),
              let record = try? JSONDecoder().decode(OracleDispatchRecord.self, from: object)
        else { continue }
        out.append(record)
    }
    return out
}
