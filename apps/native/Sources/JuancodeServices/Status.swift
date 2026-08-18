import Foundation
import JuancodeCore

/// Port of `apps/server/src/status.ts`. Gathers auth/MCP status for every
/// provider by shelling out to `claude mcp list` / `codex mcp list --json` /
/// `opencode mcp list` and parsing their (very different) outputs into one unified
/// shape.

/// `claude mcp list` health-checks every server, so give it room before timing
/// out. (TS `LIST_TIMEOUT_MS = 20_000`, in seconds here.)
private let listTimeoutSec: TimeInterval = 20
/// (TS `VERSION_TIMEOUT_MS = 5_000`.)
private let versionTimeoutSec: TimeInterval = 5
/// `maxBuffer` for the list commands (TS passes 4 MiB).
private let statusMaxBuffer = 4 * 1024 * 1024

// MARK: - Return shape (mirrors the TS exported interfaces)

/// Normalized health of a single MCP server, unified across the two CLIs.
public enum McpHealth: String, Codable, Sendable, Equatable {
    case connected
    case needsAuth = "needs-auth"
    case pending
    case failed
    case enabled
    case disabled
    case unknown
}

public struct McpServerStatus: Codable, Sendable, Equatable {
    public let name: String
    /// URL (HTTP/SSE) or command line (stdio) — whatever the CLI reports.
    public let detail: String
    /// Transport kind when known: "stdio" | "http" | "sse".
    public let transport: String?
    public let health: McpHealth
    /// Raw status text from the CLI, shown verbatim as a tooltip.
    public let statusLabel: String
    /// Auth scheme when the CLI reports it (codex): "oauth" | "bearer" | "unsupported".
    public let auth: String?

    public init(name: String, detail: String, transport: String?, health: McpHealth,
                statusLabel: String, auth: String?) {
        self.name = name; self.detail = detail; self.transport = transport
        self.health = health; self.statusLabel = statusLabel; self.auth = auth
    }
}

public struct ProviderStatus: Codable, Sendable, Equatable {
    public let id: ProviderId
    public let label: String
    /// Absolute path (or bare name) the harness will actually launch.
    public let command: String
    /// True when `<command> --version` succeeded.
    public let available: Bool
    public let version: String?
    /// Non-fatal notice surfaced by the CLI (e.g. claude's connectors-disabled banner).
    public let warning: String?
    /// Set when listing MCP servers failed; mcpServers will be empty.
    public let error: String?
    public let mcpServers: [McpServerStatus]

    public init(id: ProviderId, label: String, command: String, available: Bool,
                version: String?, warning: String?, error: String?, mcpServers: [McpServerStatus]) {
        self.id = id; self.label = label; self.command = command; self.available = available
        self.version = version; self.warning = warning; self.error = error
        self.mcpServers = mcpServers
    }
}

// MARK: - claude parsing

/// Map claude's status glyph/text to a normalized health value.
func claudeHealth(_ label: String) -> McpHealth {
    let l = label.lowercased()
    if l.contains("connected") || label.contains("✔") { return .connected }
    if l.contains("needs authentication") || l.contains("authenticate") { return .needsAuth }
    if l.contains("pending") { return .pending }
    if l.contains("failed") || label.contains("✗") { return .failed }
    return .unknown
}

/// Parse the human-readable `claude mcp list` output. Lines look like:
///   `name: https://host/mcp (HTTP) - ✔ Connected`
/// The name itself may contain colons (e.g. `plugin:linear:linear`), so we split
/// on the FIRST ": " (colon + space) and take the status after the LAST " - ".
public func parseClaudeList(_ stdout: String) -> (servers: [McpServerStatus], warning: String?) {
    var servers: [McpServerStatus] = []
    var warning: String? = nil
    for rawLine in stdout.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.hasPrefix("⚠") {
            // `line.replace(/^⚠\s*/, "")`
            warning = stripLeadingWarningGlyph(line)
            continue
        }
        if line.hasPrefix("Checking MCP server health") { continue }
        if line.hasPrefix("No MCP servers") { continue }
        // First ": " separates name from the rest (names may contain colons).
        guard let sepRange = line.range(of: ": ") else { continue }
        let name = String(line[line.startIndex..<sepRange.lowerBound])
        let rest = String(line[sepRange.upperBound...])
        // Status comes after the LAST " - " (a command line may contain " - ").
        let lastDash = rest.range(of: " - ", options: .backwards)
        let detail: String
        let statusLabel: String
        if let lastDash {
            detail = String(rest[rest.startIndex..<lastDash.lowerBound])
            statusLabel = String(rest[lastDash.upperBound...])
        } else {
            detail = rest
            statusLabel = ""
        }
        let marked = firstTransportMarker(in: detail)
        // No explicit marker → a command line is stdio; a URL is http.
        let transport = marked ?? (isHttpUrl(detail) ? "http" : "stdio")
        servers.append(McpServerStatus(
            name: name,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport,
            health: claudeHealth(statusLabel),
            statusLabel: statusLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: nil
        ))
    }
    return (servers, warning)
}

/// `line.replace(/^⚠\s*/, "")` — drop a leading ⚠ and any following whitespace.
private func stripLeadingWarningGlyph(_ line: String) -> String {
    var s = Substring(line)
    if s.first == "⚠" { s = s.dropFirst() }
    while let c = s.first, c.isWhitespace { s = s.dropFirst() }
    return String(s)
}

/// `/\((HTTP|SSE|STDIO)\)/i.exec(detail)?.[1]?.toLowerCase()` — first
/// parenthesised transport marker, lowercased, or nil.
private func firstTransportMarker(in detail: String) -> String? {
    let pattern = "\\((HTTP|SSE|STDIO)\\)"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
    guard let m = re.firstMatch(in: detail, range: range),
          let g = Range(m.range(at: 1), in: detail) else { return nil }
    return String(detail[g]).lowercased()
}

/// `/^https?:\/\//.test(detail)` — starts with http:// or https://.
private func isHttpUrl(_ detail: String) -> Bool {
    let pattern = "^https?://"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
    return re.firstMatch(in: detail, range: range) != nil
}

// MARK: - codex parsing

/// Parse `codex mcp list --json`. Codex reports config, not live connection
/// health. Returns an empty list for non-JSON / non-array input (TS `try/catch`
/// + `Array.isArray` guard).
public func parseCodexList(_ stdout: String) -> [McpServerStatus] {
    let parsed = try? JSONSerialization.jsonObject(with: Data(stdout.utf8), options: [.fragmentsAllowed])
    guard let entries = parsed as? [Any] else { return [] }
    return entries.compactMap { item in
        guard let e = item as? [String: Any] else { return nil }
        // `e.transport ?? { type: "" }`
        let t = (e["transport"] as? [String: Any]) ?? ["type": ""]
        let type = (t["type"] as? String) ?? ""
        let transport: String
        if type == "streamable_http" || type == "http" {
            transport = "http"
        } else if type == "sse" {
            transport = "sse"
        } else {
            transport = "stdio"
        }
        let detail: String
        if transport == "stdio" {
            // `[t.command, ...(t.args ?? [])].filter(Boolean).join(" ")`
            let command = t["command"] as? String
            let args = (t["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let parts = ([command].compactMap { $0 } + args).filter { !$0.isEmpty }
            detail = parts.joined(separator: " ")
        } else {
            detail = (t["url"] as? String) ?? ""
        }
        // `e.auth_status && e.auth_status !== "unsupported" ? ...replace(/_/g, "") : null`
        let authStatus = e["auth_status"] as? String
        let auth: String?
        if let authStatus, !authStatus.isEmpty, authStatus != "unsupported" {
            auth = authStatus.replacingOccurrences(of: "_", with: "")
        } else {
            auth = nil
        }
        let enabled = (e["enabled"] as? Bool) ?? false
        let disabledReason = e["disabled_reason"] as? String
        return McpServerStatus(
            name: (e["name"] as? String) ?? "",
            detail: detail,
            transport: transport,
            health: enabled ? .enabled : .disabled,
            // `e.enabled ? "enabled" : (e.disabled_reason ?? "disabled")`
            statusLabel: enabled ? "enabled" : (disabledReason ?? "disabled"),
            auth: auth
        )
    }
}

// MARK: - opencode parsing

/// Map opencode's status word to a normalized health value.
func opencodeHealth(_ label: String) -> McpHealth {
    let l = label.lowercased()
    if l.contains("connected") { return .connected }
    if l.contains("auth") { return .needsAuth }
    if l.contains("connecting") || l.contains("pending") { return .pending }
    if l.contains("failed") || l.contains("error") { return .failed }
    if l.contains("disabled") { return .disabled }
    if l.isEmpty { return .unknown }
    return .unknown
}

/// Parse `opencode mcp list`. It prints one bullet line per server followed by an
/// indented detail line:
///
///     ●  ✓ linear connected
///            https://mcp.linear.app/mcp
///
/// so a server is a bullet line (name + status) plus the next non-empty indented line
/// (its URL or command). The output is coloured and drawn with box characters, both of
/// which are stripped before matching.
public func parseOpencodeList(_ stdout: String) -> [McpServerStatus] {
    var servers: [(name: String, status: String)] = []
    var details: [Int: String] = [:]  // index into `servers` → detail line
    for rawLine in stripAnsi(stdout).components(separatedBy: "\n") {
        // Drop the tree gutter (`│`, `┌`, `└`) and surrounding whitespace.
        let line = rawLine
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t│┌└├─"))
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("●") {
            // `● ✓ name status words…` — the glyph is decoration, the first remaining
            // word is the name, the rest is the status.
            let words = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "● \t✓✗×!⚠"))
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard let name = words.first else { continue }
            servers.append((name, words.dropFirst().joined(separator: " ")))
            continue
        }
        // A trailing summary line ("4 server(s)") is not a detail.
        if line.range(of: "^[0-9]+ server", options: .regularExpression) != nil { continue }
        if !servers.isEmpty, details[servers.count - 1] == nil {
            details[servers.count - 1] = line
        }
    }
    return servers.enumerated().map { index, server in
        let detail = details[index] ?? ""
        return McpServerStatus(
            name: server.name,
            detail: detail,
            // No explicit marker: a URL is http, anything else is a command line.
            transport: detail.hasPrefix("http") ? "http" : "stdio",
            health: opencodeHealth(server.status),
            statusLabel: server.status,
            auth: nil)
    }
}

// MARK: - per-provider aggregation

/// `<command> --version` → first non-empty line, or nil on any failure. Mirrors
/// `getVersion`: the whole thing is wrapped so a launch/timeout/non-zero exit
/// all collapse to nil.
private func getVersion(command: String) async -> String? {
    do {
        let r = try await ProcessRunner.run(command, ["--version"], timeout: versionTimeoutSec)
        // `stdout.split("\n")[0]?.trim() || null`
        let first = r.stdout.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? nil : first
    } catch {
        return nil
    }
}

private func getProviderStatus(_ id: ProviderId, resolver: BinaryResolver) async -> ProviderStatus {
    let spec = Providers.spec(for: id)
    let command = resolver.command(for: id)
    let label = spec.label

    let version = await getVersion(command: command)
    if version == nil {
        return ProviderStatus(
            id: id, label: label, command: command, available: false, version: nil,
            warning: nil,
            error: "\(label) CLI not found or not runnable at \(command)",
            mcpServers: []
        )
    }

    var warning: String? = nil
    var error: String? = nil
    var mcpServers: [McpServerStatus] = []

    do {
        if id == .codex {
            let r = try await ProcessRunner.run(command, ["mcp", "list", "--json"],
                                                timeout: listTimeoutSec, maxBytes: statusMaxBuffer)
            mcpServers = parseCodexList(r.stdout)
        } else if id == .opencode {
            // opencode has no --json for this; it prints a decorated (and coloured)
            // tree, health-checking each server as it goes.
            let r = try await ProcessRunner.run(command, ["mcp", "list"],
                                                timeout: listTimeoutSec, maxBytes: statusMaxBuffer)
            mcpServers = parseOpencodeList(r.stdout)
        } else {
            let r = try await ProcessRunner.run(command, ["mcp", "list"],
                                                timeout: listTimeoutSec, maxBytes: statusMaxBuffer)
            // claude prints its connectors-disabled banner to stderr; fold it in
            // so the panel can surface it. Servers are on stdout; the parser
            // classifies per line. (TS: `parseClaudeList(`${stderr}\n${stdout}`)`.)
            let (servers, warn) = parseClaudeList("\(r.stderr)\n\(r.stdout)")
            mcpServers = servers
            warning = warn
        }
    } catch let e as ProcessError {
        error = e.message
    } catch let other {
        error = "\(other)"
    }

    return ProviderStatus(
        id: id, label: label, command: command, available: true, version: version,
        warning: warning, error: error, mcpServers: mcpServers
    )
}

/// Gather auth/MCP status for every provider, run concurrently. Iterates
/// `ProviderId.allCases` (≈ `Object.keys(PROVIDERS)`) and preserves that order,
/// matching the TS `Promise.all(...map(...))` result ordering.
public func getAllStatus(resolver: BinaryResolver = DefaultBinaryResolver()) async -> [ProviderStatus] {
    await withTaskGroup(of: (Int, ProviderStatus).self) { group in
        let ids = ProviderId.allCases
        for (index, id) in ids.enumerated() {
            group.addTask { (index, await getProviderStatus(id, resolver: resolver)) }
        }
        var collected = [ProviderStatus?](repeating: nil, count: ids.count)
        for await (index, status) in group { collected[index] = status }
        return collected.compactMap { $0 }
    }
}
