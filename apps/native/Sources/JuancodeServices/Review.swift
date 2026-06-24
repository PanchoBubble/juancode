import Foundation
import JuancodeCore

/// 'Review with Claude' — run the genuine `claude` CLI in headless print mode
/// over a session's working-tree diff and return structured findings to overlay
/// on the diff viewer.
///
/// Faithful to juancode's core promise: we launch the user's resolved `claude`
/// binary with their real environment (auth, config, MCP) untouched — exactly
/// like a session pty. We add no shadow HOME and override nothing. The only
/// thing we ask of the CLI is `-p` (non-interactive) with a JSON schema so the
/// output is machine-readable.
///
/// Port of `apps/server/src/review.ts`.

/// Cap the diff we feed the model so a huge change set can't blow up cost/latency.
private let MAX_PROMPT_BYTES = 200_000
private let REVIEW_TIMEOUT_MS = 240_000
private let MAX_BUFFER = 16 * 1024 * 1024

/// Severity rank used for both schema validation and normalization fallback.
/// Mirrors the TS `SEVERITIES` array (also the `enum` handed to the schema).
private let SEVERITIES: [ReviewSeverity] = [.critical, .high, .medium, .low, .info]

/// JSON Schema handed to `claude --json-schema` so findings come back validated.
/// Built as a Foundation object so we can JSON-serialize it for the CLI argv,
/// matching `JSON.stringify(FINDINGS_SCHEMA)` in the TS.
private func findingsSchema() -> [String: Any] {
    [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "summary": ["type": "string"],
            "findings": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "file": ["type": "string", "description": "Repo-relative path exactly as it appears in the diff header"],
                        "side": ["type": "string", "enum": ["old", "new"], "description": "'new' for added/context lines, 'old' for removed lines"],
                        "line": [
                            "type": ["integer", "null"],
                            "description": "Line number on the chosen side; null for a file-level finding with no single line",
                        ],
                        "severity": ["type": "string", "enum": SEVERITIES.map { $0.rawValue }],
                        "title": ["type": "string", "description": "One-line summary of the issue"],
                        "note": ["type": "string", "description": "What's wrong and how to fix it"],
                    ],
                    "required": ["file", "side", "line", "severity", "title", "note"],
                ],
            ],
        ],
        "required": ["summary", "findings"],
    ]
}

private let SYSTEM_PROMPT =
    "You are a meticulous senior code reviewer. You are given a unified git diff of a working tree. " +
    "Review ONLY the changes shown — bugs, correctness, security, error handling, and clear quality issues. " +
    "Anchor each finding to the file and line it concerns, using the line numbers from the diff's new side " +
    "(removed lines use the old side). Be concrete and skip nitpicks and style preferences. " +
    "If the diff looks clean, return an empty findings array with a short summary saying so. " +
    "Respond ONLY via the structured output schema."

/// Build the user prompt: the diff plus any human inline comments as steering context.
public func buildPrompt(_ files: [DiffFile], _ comments: [DiffComment]) -> String {
    var parts: [String] = []
    parts.append("Review the following working-tree changes.\n")

    if comments.count > 0 {
        parts.append(
            "The human reviewer left these inline comments — treat them as priorities and respond to their concerns where relevant:"
        )
        for c in comments {
            let lines = c.endLine > c.line ? "\(c.line)-\(c.endLine)" : "\(c.line)"
            parts.append("- \(c.file):\(lines) (\(c.side.rawValue)) — \(c.body)")
        }
        parts.append("")
    }

    parts.append("Unified diff:\n")
    for f in files {
        let header = f.oldPath != nil ? "\(f.oldPath!) → \(f.path)" : f.path
        parts.append("### \(header) (\(f.status.rawValue), +\(f.additions) −\(f.deletions))")
        if f.binary {
            parts.append("(binary file — no textual diff)")
        } else if f.truncated {
            parts.append("(diff too large — omitted)")
        } else if !f.diff.isEmpty {
            parts.append("```diff\n" + f.diff + "\n```")
        }
        parts.append("")
    }

    var prompt = parts.joined(separator: "\n")
    if prompt.count > MAX_PROMPT_BYTES {
        prompt = String(prompt.prefix(MAX_PROMPT_BYTES)) + "\n\n[diff truncated for length — review what is shown]"
    }
    return prompt
}

/// Shape of the `claude -p --output-format json` envelope we care about.
private struct ClaudeEnvelope {
    var type: String?
    var subtype: String?
    var isError: Bool?
    var result: String?
}

/// Parse `claude -p --output-format json` stdout into findings.
/// The envelope's `result` field holds the schema-validated JSON as a string.
/// Returns an error result on any failure rather than throwing — the route maps
/// it straight to the UI.
public func parseReviewOutput(_ stdout: String, _ createdAt: Int) -> ReviewResult {
    // First parse the outer envelope. Anything non-JSON → error result.
    guard let envelopeObj = jsonObject(from: stdout) else {
        return ReviewResult(status: .error, findings: [], summary: nil, createdAt: createdAt,
                            error: "Could not parse CLI output.")
    }
    let envelope = ClaudeEnvelope(
        type: envelopeObj["type"] as? String,
        subtype: envelopeObj["subtype"] as? String,
        isError: envelopeObj["is_error"] as? Bool,
        // `typeof envelope.result === "string"`: only treat a real string as a result.
        result: envelopeObj["result"] as? String
    )

    if envelope.isError == true || envelope.subtype != "success" || envelope.result == nil {
        return ReviewResult(
            status: .error,
            findings: [],
            summary: nil,
            createdAt: createdAt,
            error: (envelope.result?.isEmpty == false) ? envelope.result! : "Review run failed."
        )
    }

    let resultStr = envelope.result!
    // The `result` string should itself be schema-shaped JSON. If it isn't, keep
    // the prose as the summary so the user still sees something.
    guard let payload = jsonObject(from: resultStr) else {
        let trimmed = resultStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewResult(status: .ok, findings: [], summary: trimmed.isEmpty ? nil : trimmed,
                            createdAt: createdAt)
    }

    let findings: [ReviewFinding]
    if let rawFindings = payload["findings"] as? [Any] {
        findings = rawFindings.compactMap { normalizeFinding($0) }
    } else {
        findings = []
    }
    let summary: String?
    if let s = payload["summary"] as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = trimmed.isEmpty ? nil : trimmed
    } else {
        summary = nil
    }
    return ReviewResult(status: .ok, findings: findings, summary: summary, createdAt: createdAt)
}

/// Coerce one raw finding object into a `ReviewFinding`, or drop it (return nil).
/// Mirrors the TS `normalizeFinding`: clamp bad sides/severities/lines, drop a
/// finding with no `file` or with neither title nor note.
private func normalizeFinding(_ raw: Any) -> ReviewFinding? {
    guard let r = raw as? [String: Any] else { return nil }
    guard let file = r["file"] as? String, !file.isEmpty else { return nil }
    // Anything other than the literal "old" maps to "new" (matches `r.side === "old" ? "old" : "new"`).
    let side: CommentSide = (r["side"] as? String) == "old" ? .old : .new
    // `Number.isInteger(r.line)` — only a genuine integer survives; strings/floats/null → nil.
    let line: Int? = integerValue(r["line"])
    // Unknown severities fall back to "info".
    let severity: ReviewSeverity = severityValue(r["severity"]) ?? .info
    let title = (r["title"] as? String) ?? ""
    let note = (r["note"] as? String) ?? ""
    if title.isEmpty && note.isEmpty { return nil }
    return ReviewFinding(file: file, side: side, line: line, severity: severity, title: title, note: note)
}

/// Match `Number.isInteger(x)`: accept an integral number, reject strings,
/// fractional numbers, booleans and null.
private func integerValue(_ value: Any?) -> Int? {
    // JSONSerialization decodes JSON numbers as NSNumber. Distinguish integers
    // from booleans (NSNumber wraps both) and from fractional values.
    guard let num = value as? NSNumber else { return nil }
    // Booleans are NSNumber too; exclude them — JS `Number.isInteger(true)` is false.
    if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
    let d = num.doubleValue
    guard d.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
    return num.intValue
}

private func severityValue(_ value: Any?) -> ReviewSeverity? {
    guard let s = value as? String, let sev = ReviewSeverity(rawValue: s), SEVERITIES.contains(sev) else {
        return nil
    }
    return sev
}

/// Parse a string as a JSON object, returning nil on any failure (mirrors a
/// `try { JSON.parse(...) } catch { ... }` around an object-shaped payload).
private func jsonObject(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    let obj = try? JSONSerialization.jsonObject(with: data, options: [])
    return obj as? [String: Any]
}

/// Errors surfaced by `runClaude`, carrying the exact message the TS would set.
private struct ReviewRunError: Error {
    let message: String
}

/// Run the CLI, feeding the prompt over stdin so a large diff can't hit ARG_MAX.
private func runClaude(_ prompt: String, _ cwd: String, resolver: BinaryResolver) async throws -> String {
    let command = resolver.command(for: .claude)
    let schemaJSON = String(
        decoding: (try? JSONSerialization.data(withJSONObject: findingsSchema(), options: [])) ?? Data(),
        as: UTF8.self
    )
    let args = [
        "-p", "--output-format", "json",
        "--json-schema", schemaJSON,
        "--append-system-prompt", SYSTEM_PROMPT,
    ]

    let result: ProcessResult
    do {
        // `capture` returns on any exit code; it throws only on launch-fail / timeout
        // / output-too-large, which we translate to the TS error messages below.
        result = try await ProcessRunner.capture(
            command, args, cwd: cwd,
            timeout: TimeInterval(REVIEW_TIMEOUT_MS) / 1000,
            stdin: prompt, maxBytes: MAX_BUFFER
        )
    } catch let e as ProcessError {
        if e.timedOut { throw ReviewRunError(message: "Review timed out.") }
        // A launch failure (≈ spawn 'error') surfaces the underlying error text,
        // just as the TS rejects with the child's `error`.
        throw ReviewRunError(message: e.message)
    }

    // claude -p exits non-zero on hard failure; the JSON envelope (when present)
    // carries the real error, so prefer stdout and only fall back to stderr.
    if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return result.stdout
    }
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    throw ReviewRunError(message: stderr.isEmpty ? "claude exited with code \(result.exitCode)" : stderr)
}

/// Run a full review pass and return a result ready to cache and serve.
public func runReview(
    cwd: String,
    files: [DiffFile],
    comments: [DiffComment],
    now: Int,
    resolver: BinaryResolver = DefaultBinaryResolver()
) async -> ReviewResult {
    if files.isEmpty {
        return ReviewResult(status: .empty, findings: [], summary: nil, createdAt: now)
    }
    do {
        let stdout = try await runClaude(buildPrompt(files, comments), cwd, resolver: resolver)
        return parseReviewOutput(stdout, now)
    } catch let e as ReviewRunError {
        return ReviewResult(status: .error, findings: [], summary: nil, createdAt: now, error: e.message)
    } catch {
        return ReviewResult(status: .error, findings: [], summary: nil, createdAt: now,
                            error: "\(error)")
    }
}
