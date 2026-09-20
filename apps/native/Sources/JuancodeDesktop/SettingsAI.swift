import Foundation
import JuancodeCore

/// 'Ask AI to change my settings' — run the genuine `claude` CLI in headless print
/// mode with a JSON schema and return a validated settings *patch* the UI previews
/// and applies on confirm.
///
/// Faithful to juancode's core promise (same as `Review.swift`): we launch the
/// user's resolved `claude` binary with their real environment (auth, config, MCP)
/// untouched. The only thing we ask of the CLI is `-p` (non-interactive) with a
/// JSON schema so the reply is machine-readable. No Anthropic API key, no shadow
/// HOME — it inherits the CLI the user already signed into.

private let SETTINGS_AI_TIMEOUT_MS = 120_000
private let SETTINGS_MAX_BUFFER = 4 * 1024 * 1024

/// The user preferences the AI is allowed to touch, with current values so a
/// relative request ("bump the budget by $10", "turn it off") resolves correctly.
/// The view fills this from `AppModel`; the engine embeds it in the prompt.
public struct SettingsSnapshot: Sendable {
    public var autoCloseIdleMinutes: Int
    public var costBudgetUsd: Double
    public var costBudgetWarnPercent: Int
    public var notifyOnTurnEnd: Bool
    public var keepAwake: Bool
    public var theme: String          // "system" | "light" | "dark"
    public var hasWebhook: Bool       // whether a notification webhook URL is set

    public init(autoCloseIdleMinutes: Int, costBudgetUsd: Double, costBudgetWarnPercent: Int,
                notifyOnTurnEnd: Bool, keepAwake: Bool, theme: String, hasWebhook: Bool) {
        self.autoCloseIdleMinutes = autoCloseIdleMinutes
        self.costBudgetUsd = costBudgetUsd
        self.costBudgetWarnPercent = costBudgetWarnPercent
        self.notifyOnTurnEnd = notifyOnTurnEnd
        self.keepAwake = keepAwake
        self.theme = theme
        self.hasWebhook = hasWebhook
    }
}

/// A patch the AI proposes: every field is optional — only the ones it wants to
/// change are present. `clearWebhook` is the only webhook control (the AI may turn
/// a webhook off but never invent a URL). Bounds are re-clamped on apply.
public struct SettingsPatch: Sendable, Equatable {
    public var autoCloseIdleMinutes: Int?
    public var costBudgetUsd: Double?
    public var costBudgetWarnPercent: Int?
    public var notifyOnTurnEnd: Bool?
    public var keepAwake: Bool?
    public var theme: String?
    public var clearWebhook: Bool?

    public init() {}

    public var isEmpty: Bool {
        autoCloseIdleMinutes == nil && costBudgetUsd == nil && costBudgetWarnPercent == nil
            && notifyOnTurnEnd == nil && keepAwake == nil && theme == nil && clearWebhook != true
    }
}

/// The engine's outcome: a patch (possibly empty) with the model's short explanation,
/// or an error message to surface verbatim.
public struct SettingsAIResult: Sendable {
    public var patch: SettingsPatch
    public var explanation: String
    public var error: String?

    public init(patch: SettingsPatch = SettingsPatch(), explanation: String = "", error: String? = nil) {
        self.patch = patch
        self.explanation = explanation
        self.error = error
    }
}

/// JSON Schema handed to `claude --json-schema`. All settings fields optional so the
/// model returns only what changes; `explanation` is required so the preview always
/// has a one-line rationale.
private func settingsSchema() -> [String: Any] {
    [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "autoCloseIdleMinutes": ["type": "integer", "description": "Minutes of inactivity before an idle session is put to sleep. 0 disables it. Sensible range 5-1440."],
            "costBudgetUsd": ["type": "number", "description": "Estimated-cost budget ceiling in USD. 0 disables the budget warning."],
            "costBudgetWarnPercent": ["type": "integer", "description": "Percent of budget (10-100) at which the total turns amber."],
            "notifyOnTurnEnd": ["type": "boolean", "description": "Whether a session finishing a turn bounces the Dock and bumps the unread badge."],
            "keepAwake": ["type": "boolean", "description": "Whether the Mac is blocked from idle-sleeping while sessions run."],
            "theme": ["type": "string", "enum": ["system", "light", "dark"], "description": "App appearance."],
            "clearWebhook": ["type": "boolean", "description": "Set true ONLY to turn off / clear the notification webhook. You cannot set a webhook URL."],
            "explanation": ["type": "string", "description": "One short sentence describing the change, or why nothing changed."],
        ],
        "required": ["explanation"],
    ]
}

private func systemPrompt(_ s: SettingsSnapshot) -> String {
    """
    You adjust the settings of a macOS developer tool called juancode. The user will \
    describe, in plain language, what they want changed. Respond ONLY via the structured \
    output schema: include a field only when you are changing it, and always include a \
    short `explanation`.

    Current settings:
    - autoCloseIdleMinutes: \(s.autoCloseIdleMinutes) (0 = disabled)
    - costBudgetUsd: \(s.costBudgetUsd) (0 = disabled)
    - costBudgetWarnPercent: \(s.costBudgetWarnPercent)
    - notifyOnTurnEnd: \(s.notifyOnTurnEnd)
    - keepAwake: \(s.keepAwake)
    - theme: \(s.theme)
    - notification webhook set: \(s.hasWebhook)

    Rules: resolve relative requests against the current values. Respect bounds \
    (warn percent 10-100; idle minutes 0 or 5-1440). You may turn the webhook OFF via \
    clearWebhook, but you can never set a webhook URL. If the request doesn't map to any \
    setting, change nothing and say so in the explanation.
    """
}

/// Same envelope shape as `Review.swift`'s `claude -p --output-format json` output.
private func jsonObject(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
}

/// Match `Number.isInteger`: accept an integral number, reject bools/strings/fractions.
private func integerValue(_ value: Any?) -> Int? {
    guard let num = value as? NSNumber else { return nil }
    if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
    let d = num.doubleValue
    guard d.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
    return num.intValue
}

private func doubleValue(_ value: Any?) -> Double? {
    guard let num = value as? NSNumber else { return nil }
    if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
    return num.doubleValue
}

private func boolValue(_ value: Any?) -> Bool? {
    guard let num = value as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else { return nil }
    return num.boolValue
}

/// Parse the CLI envelope, then the inner schema-validated `result` string, into a patch.
func parseSettingsOutput(_ stdout: String) -> SettingsAIResult {
    guard let envelope = jsonObject(from: stdout) else {
        return SettingsAIResult(error: "Could not parse CLI output.")
    }
    let isError = envelope["is_error"] as? Bool
    let subtype = envelope["subtype"] as? String
    let result = envelope["result"] as? String
    if isError == true || subtype != "success" || result == nil {
        let msg = (result?.isEmpty == false) ? result! : "Settings run failed."
        return SettingsAIResult(error: msg)
    }
    guard let payload = jsonObject(from: result!) else {
        // No schema-shaped JSON — keep the prose so the user sees something.
        let trimmed = result!.trimmingCharacters(in: .whitespacesAndNewlines)
        return SettingsAIResult(explanation: trimmed.isEmpty ? "No change." : trimmed)
    }

    var patch = SettingsPatch()
    patch.autoCloseIdleMinutes = integerValue(payload["autoCloseIdleMinutes"])
    patch.costBudgetUsd = doubleValue(payload["costBudgetUsd"])
    patch.costBudgetWarnPercent = integerValue(payload["costBudgetWarnPercent"])
    patch.notifyOnTurnEnd = boolValue(payload["notifyOnTurnEnd"])
    patch.keepAwake = boolValue(payload["keepAwake"])
    if let t = payload["theme"] as? String, ["system", "light", "dark"].contains(t) { patch.theme = t }
    patch.clearWebhook = boolValue(payload["clearWebhook"])

    let explanation = (payload["explanation"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return SettingsAIResult(patch: patch, explanation: explanation)
}

/// Run one headless `claude -p` settings turn. Returns an error result rather than
/// throwing — the view maps it straight to the UI.
public func runSettingsAI(
    prompt userPrompt: String,
    current: SettingsSnapshot,
    resolver: BinaryResolver = DefaultBinaryResolver()
) async -> SettingsAIResult {
    let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return SettingsAIResult(error: "Type what you want changed.") }

    let command = resolver.command(for: .claude)
    let schemaJSON = String(
        decoding: (try? JSONSerialization.data(withJSONObject: settingsSchema(), options: [])) ?? Data(),
        as: UTF8.self)
    let args = [
        "-p", "--output-format", "json",
        "--json-schema", schemaJSON,
        "--append-system-prompt", systemPrompt(current),
    ]

    let result: ProcessResult
    do {
        result = try await ProcessRunner.capture(
            command, args, cwd: NSHomeDirectory(),
            timeout: TimeInterval(SETTINGS_AI_TIMEOUT_MS) / 1000,
            stdin: trimmed, maxBytes: SETTINGS_MAX_BUFFER)
    } catch let e as ProcessError {
        if e.timedOut { return SettingsAIResult(error: "Timed out.") }
        return SettingsAIResult(error: e.message)
    } catch {
        return SettingsAIResult(error: "\(error)")
    }

    if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return parseSettingsOutput(result.stdout)
    }
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return SettingsAIResult(error: stderr.isEmpty ? "claude exited with code \(result.exitCode)" : stderr)
}
