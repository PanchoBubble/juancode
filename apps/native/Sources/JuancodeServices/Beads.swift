import Foundation
import JuancodeCore

/// Port of `apps/server/src/beads.ts`. Lists a work folder's bd (beads) issues,
/// flagged ready/blocked, degrading gracefully (never throwing) when bd is
/// missing or the folder has no tracker.

/// Captured output cap, mirroring the TS `MAX_BUFFER`.
private let beadsMaxBuffer = 16 * 1024 * 1024
/// Per-invocation timeout, mirroring the TS `TIMEOUT_MS` (10s, in seconds here).
private let beadsTimeoutSec: TimeInterval = 10

/// The `bd` binary, resolved like the user's terminal would (see resolveBin).
/// Resolved per-call (rather than once at module load like the TS top-level
/// const) so the `JUANCODE_BD_BIN` override can be set by tests after import —
/// functionally identical since the override is read the same way every time.
private func bdBin() -> String {
    resolveBin("bd", override: ProcessInfo.processInfo.environment["JUANCODE_BD_BIN"])
}

/// Thrown when `bd` exits non-zero (or can't be launched / times out). Carries
/// the bits `describe` branches on, mirroring how Node's `execFile` rejection
/// exposes `err.code` ("ENOENT") and `err.stderr`.
private struct BdError: Error {
    let launchFailed: Bool
    let stderr: String
    /// Fallback message when there's no stderr (mirrors `err.message`).
    let message: String
}

/// Run `bd` in `cwd` and parse its JSON stdout. We pass `--sandbox` (read-only:
/// no sync/autopush) since this is a polled, view-only panel. Inherits the
/// user's real env untouched — never a shadow HOME — so bd resolves the same
/// `.beads` tracker it would in their terminal.
///
/// Returns the parsed JSON value (`Any?`) — `JSON.parse(stdout || "null")` in
/// the TS, so empty stdout yields `nil`.
private func bdJson(_ cwd: String, _ args: [String]) async throws -> Any? {
    let result: ProcessResult
    do {
        result = try await ProcessRunner.capture(
            bdBin(), ["--sandbox"] + args + ["--json"],
            cwd: cwd, timeout: beadsTimeoutSec, maxBytes: beadsMaxBuffer
        )
    } catch let e as ProcessError {
        // Launch failure (≈ ENOENT) or timeout — surface as a BdError so the
        // caller's `describe` can classify it.
        throw BdError(launchFailed: e.launchFailed, stderr: e.stderr, message: e.message)
    }
    // execFile rejects on a non-zero exit; mirror that so the catch sites in
    // getBeads behave the same (return unavailable / fall back to empty set).
    guard result.ok else {
        throw BdError(launchFailed: false, stderr: result.stderr,
                      message: "bd exited with code \(result.exitCode)")
    }
    let trimmed = result.stdout.isEmpty ? "null" : result.stdout
    let data = Data(trimmed.utf8)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// Collect the `id` of each issue in a `bd` list-like JSON value, mirroring the
/// TS `idsOf`: non-arrays → empty set; each element's `id` coerced to a string;
/// empty/missing ids dropped.
private func idsOf(_ value: Any?) -> Set<String> {
    guard let arr = value as? [Any] else { return [] }
    var ids = Set<String>()
    for item in arr {
        let dict = item as? [String: Any]
        let id = stringify(dict?["id"]) ?? ""
        if !id.isEmpty { ids.insert(id) }
    }
    return ids
}

/// Coerce a JSON scalar to a string the way `String(value)` would in JS for the
/// values bd emits (string ids, or occasionally numeric ids). Returns nil only
/// for `null`/missing so callers can apply their own default.
private func stringify(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return numberToString(n) }
    return String(describing: value)
}

/// Render an `NSNumber` as JS `String(n)` would: integers without a decimal
/// point, booleans as true/false (bd shouldn't emit bool ids, but be faithful).
private func numberToString(_ n: NSNumber) -> String {
    if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return n.boolValue ? "true" : "false"
    }
    let d = n.doubleValue
    if d == d.rounded() && abs(d) < 9_007_199_254_740_992 {
        return String(Int64(d))
    }
    return String(d)
}

/// List a work folder's bd issues, flagged ready/blocked. Returns
/// `available: false` (never throws) when bd is missing or the folder has no
/// tracker, so the UI can degrade gracefully instead of erroring.
public func getBeads(_ cwd: String) async -> BeadsResult {
    let raw: [[String: Any]]
    do {
        let value = try await bdJson(cwd, ["list"])
        // `(await bdJson(...)) ?? []` — null stdout becomes an empty listing.
        raw = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    } catch {
        return BeadsResult(available: false, issues: [], error: describe(error))
    }

    // ready/blocked are best-effort overlays — a failure here just leaves the
    // flags false rather than failing the whole listing. Run concurrently
    // (TS `Promise.all`), each `.catch`-ing to an empty set.
    async let readyTask: Set<String> = {
        do { return idsOf(try await bdJson(cwd, ["ready", "--limit", "1000"])) }
        catch { return [] }
    }()
    async let blockedTask: Set<String> = {
        do { return idsOf(try await bdJson(cwd, ["blocked"])) }
        catch { return [] }
    }()
    let ready = await readyTask
    let blocked = await blockedTask

    let issues: [BeadsIssue] = raw
        // Mirror `.filter((r) => r.id)`: drop entries with a falsy id. bd ids
        // are strings, so a missing/null/empty id is the faithful falsy guard.
        .filter { r in
            guard let id = stringify(r["id"]), !id.isEmpty else { return false }
            return true
        }
        .map { r in
            let id = stringify(r["id"]) ?? ""
            return BeadsIssue(
                id: id,
                title: (r["title"] as? String) ?? "",
                status: (r["status"] as? String) ?? "open",
                // `typeof r.priority === "number" ? r.priority : 2`
                priority: intIfNumber(r["priority"]) ?? 2,
                issueType: (r["issue_type"] as? String) ?? "task",
                // `r.parent ?? null` — keep string parents, drop null/missing.
                parent: r["parent"] as? String,
                dependencyCount: intIfNumber(r["dependency_count"]) ?? 0,
                dependentCount: intIfNumber(r["dependent_count"]) ?? 0,
                ready: ready.contains(id),
                blocked: blocked.contains(id)
            )
        }

    return BeadsResult(available: true, issues: issues)
}

/// Return an `Int` only when the JSON value is genuinely a number (not a numeric
/// string), mirroring the TS `typeof x === "number"` guard. Booleans are
/// `NSNumber`s in JSONSerialization, so exclude them explicitly.
private func intIfNumber(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.intValue
}

/// Turn a thrown error into the user-facing string the panel shows, mirroring
/// the TS `describe`: ENOENT → "not found"; "no beads database" stderr → no
/// tracker; otherwise the trimmed stderr, then the error message.
private func describe(_ err: Error) -> String {
    guard let e = err as? BdError else {
        return (err as NSError).localizedDescription
    }
    if e.launchFailed { return "bd CLI not found on PATH" }
    let stderr = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if stderr.contains("no beads database") { return "No beads tracker in this folder" }
    return !stderr.isEmpty ? stderr : e.message
}

// MARK: - prompt builder (juancode-sfh)

/// Fetch the full details for a single issue (`bd show <id> --json`), returning
/// its `description` if present. Degrades to `nil` (never throws) when bd is
/// missing or the id is unknown, so callers fall back to the list-only fields.
///
/// `bd show --json` emits an array with a single object; we read `[0].description`.
public func getBeadsDescription(_ cwd: String, id: String) async -> String? {
    guard !id.isEmpty else { return nil }
    do {
        let value = try await bdJson(cwd, ["show", id])
        let first = (value as? [Any])?.first as? [String: Any]
        let desc = (first?["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (desc?.isEmpty ?? true) ? nil : desc
    } catch {
        return nil
    }
}

/// Compose the context blob injected into an agent session when the user picks an
/// issue to "work on". Pure so it can be unit-tested. Template:
/// `Work on <id>: <title>\n\n<description>` — the trailing description block is
/// omitted entirely when there is none, leaving just the one-line `Work on …`.
/// Side-effect-free by design (juancode-sfh): it never mutates the issue's status.
public func issuePrompt(id: String, title: String, description: String? = nil) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let header = trimmedTitle.isEmpty ? "Work on \(id)" : "Work on \(id): \(trimmedTitle)"
    let body = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return body.isEmpty ? header : "\(header)\n\n\(body)"
}
