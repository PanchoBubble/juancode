import Foundation
import JuancodeCore

/// Derives per-session token usage (and an estimated cost) from the CLI's own
/// transcript files — the same robust source `SessionTitle.swift` reads, rather
/// than scraping the ANSI TUI stream.
///
///   - Claude writes one `assistant` record per API turn into
///     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`, each carrying a
///     `message.usage` block. The same turn can be logged more than once, so we
///     dedup by `message.id` + `requestId` (the key `ccusage` uses) before
///     summing. Cost is summed per message using that message's model.
///   - Codex emits a running `token_count` event whose `info.total_token_usage`
///     is cumulative — we just take the last one.
///
/// Cost is a best-effort *estimate* from published per-MTok rates (below). For a
/// model we don't have a price for — or Codex, which doesn't expose a per-token
/// price (and is usually a subscription) — `costUsd` is nil and only tokens are
/// shown. Subscription users pay nothing per token regardless, so the figure is
/// labelled an estimate in the UI.
///
/// Returns nil when no usage is available yet (e.g. before the first turn).

/// Override the transcript roots (used by tests to point at fixtures).
public struct UsageRoots {
    public var claudeProjects: String?
    public var codexSessions: String?
    public init(claudeProjects: String? = nil, codexSessions: String? = nil) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
    }
}

/// Published input/output price per **million** tokens, by model-id match.
private struct ModelPrice {
    /// Matches against the transcript's model id (substring/prefix), case-insensitive.
    let match: String
    let inputPerMTok: Double
    let outputPerMTok: Double
}

/// Current Claude pricing (USD per 1M tokens). Cache reads bill at ~0.1× input
/// and cache writes at ~1.25× input (5-minute TTL, the default), applied below.
/// Ordered most-specific first; the first match wins.
private let MODEL_PRICES: [ModelPrice] = [
    ModelPrice(match: "opus", inputPerMTok: 5, outputPerMTok: 25),
    ModelPrice(match: "sonnet", inputPerMTok: 3, outputPerMTok: 15),
    ModelPrice(match: "haiku", inputPerMTok: 1, outputPerMTok: 5),
    ModelPrice(match: "fable|mythos", inputPerMTok: 10, outputPerMTok: 50),
]

private let CACHE_READ_MULT = 0.1
private let CACHE_WRITE_MULT = 1.25

private func priceFor(_ model: String) -> ModelPrice? {
    // Mirrors `MODEL_PRICES.find((p) => p.match.test(model))` with case-insensitive
    // regex matching; the last entry uses an alternation (`fable|mythos`).
    return MODEL_PRICES.first { p in
        model.range(of: p.match, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Resolving a transcript path means scanning a directory tree, wasteful to
/// repeat on every poll. Cache the resolved path per CLI session id once found.
///
/// (Separate from `SessionTitle`'s cache, mirroring the per-module `Map` in TS.)
private final class FileCache: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }
}
private let fileCache = FileCache()

/// Namespace for this module's read positions in `TranscriptReader` (the title poll
/// reads the same files at its own pace under its own namespace).
private let usageNamespace = "usage"

/// Running usage state for one session, carried across polls so each 4s pass only
/// has to fold in the records the CLI appended since the last one (juancode-dfhg).
/// `seen` persists too: the same turn is sometimes logged twice, and the duplicate
/// can land in a later pass than the original.
private struct UsageAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// Summed per-message cost; only meaningful while `costKnown`.
    var costUsd = 0.0
    /// Stays true only while every priced turn had a known model.
    var costKnown = true
    var sawTurn = false
    /// `message.id` + `requestId` of every turn already counted.
    var seen: Set<String> = []

    /// The public projection: totals summed, cost dropped when any turn's model was
    /// un-priced, nil until a real assistant turn has been counted.
    var usage: SessionUsage? {
        guard sawTurn else { return nil }
        return SessionUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens,
            costUsd: costKnown ? costUsd : nil)
    }
}

/// The cumulative tally Codex reports, carried across polls for the same reason.
private struct CodexTotals {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var totalTokens = 0

    var usage: SessionUsage {
        SessionUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: 0,
            totalTokens: totalTokens,
            costUsd: nil)
    }
}

/// Per-session running usage state, keyed by CLI session id.
private final class UsageStateStore: @unchecked Sendable {
    private var claude: [String: UsageAccumulator] = [:]
    private var codex: [String: CodexTotals] = [:]
    private let lock = NSLock()

    func claudeState(_ id: String) -> UsageAccumulator? {
        lock.withLock { claude[id] }
    }
    func setClaude(_ id: String, _ acc: UsageAccumulator) {
        lock.withLock { claude[id] = acc }
    }
    func codexState(_ id: String) -> CodexTotals? {
        lock.withLock { codex[id] }
    }
    func setCodex(_ id: String, _ totals: CodexTotals) {
        lock.withLock { codex[id] = totals }
    }
    func clearCodex(_ id: String) {
        lock.withLock { _ = codex.removeValue(forKey: id) }
    }
}
private let usageState = UsageStateStore()

/// Coerce a JSON numeric value to Int (transcript token fields are integers).
/// Falls back to `fallback` when absent or non-numeric, matching `?? 0`.
private func intField(_ dict: [String: Any]?, _ key: String, _ fallback: Int = 0) -> Int {
    guard let v = dict?[key] else { return fallback }
    if let n = v as? Int { return n }
    if let n = v as? Double { return Int(n) }
    if let n = v as? NSNumber { return n.intValue }
    return fallback
}

/// Token usage + estimated cost for a Claude session, summed across messages.
public func deriveClaudeUsage(
    _ cliSessionId: String,
    _ root: String = CLAUDE_PROJECTS
) async -> SessionUsage? {
    var file = fileCache.get(cliSessionId)
    if file == nil {
        guard let found = await findByBasename(root, "\(cliSessionId).jsonl") else { return nil }
        fileCache.set(cliSessionId, found)
        file = found
    }

    // Fold only the records appended since the last poll into the session's running
    // totals. Starting from the remembered state is what makes a poll with nothing
    // new a no-op; `onStart` only fires when the reader had to restart from the top
    // of the file, in which case the accumulated state is stale and must be rebuilt.
    var acc = usageState.claudeState(cliSessionId) ?? UsageAccumulator()
    TranscriptReader.shared.scan(file: file!, namespace: usageNamespace, onStart: { fromStart in
        if fromStart { acc = UsageAccumulator() }
    }) { rec in
        addClaudeTurn(rec, to: &acc)
        return nil
    }
    usageState.setClaude(cliSessionId, acc)
    return acc.usage
}

/// Fold one transcript record into `acc` if it is a billable assistant turn we
/// haven't already counted.
private func addClaudeTurn(_ rec: [String: Any], to acc: inout UsageAccumulator) {
    guard rec["type"] as? String == "assistant" else { return }
    let msg = rec["message"] as? [String: Any]
    guard let u = msg?["usage"] as? [String: Any] else { return }

    // Dedup: the same API response is sometimes written multiple times.
    let msgId = msg?["id"] as? String ?? ""
    let requestId = rec["requestId"] as? String ?? ""
    let key = "\(msgId):\(requestId)"
    if key != ":" && acc.seen.contains(key) { return }
    acc.seen.insert(key)

    let model = msg?["model"] as? String ?? ""
    if model == "<synthetic>" { return }  // local message, not a billed API call

    let input = intField(u, "input_tokens")
    let output = intField(u, "output_tokens")
    let cacheRead = intField(u, "cache_read_input_tokens")
    let cacheWrite = intField(u, "cache_creation_input_tokens")

    acc.sawTurn = true
    acc.inputTokens += input
    acc.outputTokens += output
    acc.cacheReadTokens += cacheRead
    acc.cacheWriteTokens += cacheWrite

    if let price = priceFor(model) {
        acc.costUsd +=
            (Double(input) * price.inputPerMTok
                + Double(cacheRead) * price.inputPerMTok * CACHE_READ_MULT
                + Double(cacheWrite) * price.inputPerMTok * CACHE_WRITE_MULT
                + Double(output) * price.outputPerMTok)
            / 1_000_000
    } else {
        acc.costKnown = false  // an un-priced model means the total is only partial
    }
}

/// Token usage for a Codex session: the last cumulative `token_count` event.
public func deriveCodexUsage(
    _ cliSessionId: String,
    _ root: String = CODEX_SESSIONS
) async -> SessionUsage? {
    // Rollout already resolved: tail-read only what was appended since the last poll
    // and keep the newest cumulative tally (juancode-dfhg).
    if let cached = fileCache.get(cliSessionId) {
        var latest: CodexTotals? = nil
        let scan = TranscriptReader.shared.scan(file: cached, namespace: usageNamespace) { rec in
            guard let payload = rec["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return nil }
            latest = codexTotals(from: total)
            return nil
        }
        if scan.fromStart { usageState.clearCodex(cliSessionId) }
        if let latest { usageState.setCodex(cliSessionId, latest) }
        // Matched the session but no turn has run yet ⇒ still nil.
        return usageState.codexState(cliSessionId)?.usage
    }

    // Discovery: matching a rollout to a session id means reading its `session_meta`,
    // so these passes stay whole-file. Once one matches, the path is cached and every
    // later poll takes the incremental path above.
    let files = await codexRolloutFiles(root)

    for full in files {
        var isMatch = false
        var total: [String: Any]? = nil
        await forEachRecord(full) { rec in
            let payload = rec["payload"] as? [String: Any]
            if rec["type"] as? String == "session_meta" {
                if (payload?["id"] as? String) != cliSessionId { return false }  // wrong file — bail
                isMatch = true
                return nil
            }
            // Cumulative tally; keep the latest. (When reading a cached file directly
            // we never see session_meta, but isMatch is already true.)
            if isMatch, payload?["type"] as? String == "token_count",
               let info = payload?["info"] as? [String: Any],
               let totalUsage = info["total_token_usage"] as? [String: Any] {
                total = totalUsage
            }
            return nil
        }
        if isMatch {
            fileCache.set(cliSessionId, full)
            guard let t = total else { return nil }  // matched the session but no turn has run yet
            let totals = codexTotals(from: t)
            usageState.setCodex(cliSessionId, totals)
            return totals.usage
        }
    }
    return nil
}

/// Read Codex's cumulative `total_token_usage` block into totals. Its
/// `input_tokens` already includes the cached portion, so the cached tokens are
/// subtracted out to report fresh input separately. Codex exposes no per-token
/// price, so cost stays nil (see `CodexTotals.usage`).
private func codexTotals(from total: [String: Any]) -> CodexTotals {
    let cacheRead = intField(total, "cached_input_tokens")
    let input = max(0, intField(total, "input_tokens") - cacheRead)
    let output = intField(total, "output_tokens")
    return CodexTotals(
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        totalTokens: intField(total, "total_tokens", input + output + cacheRead))
}

public func deriveSessionUsage(
    _ provider: ProviderId,
    _ cliSessionId: String,
    _ roots: UsageRoots = UsageRoots()
) async -> SessionUsage? {
    if provider == .claude {
        return await deriveClaudeUsage(cliSessionId, roots.claudeProjects ?? CLAUDE_PROJECTS)
    } else {
        return await deriveCodexUsage(cliSessionId, roots.codexSessions ?? CODEX_SESSIONS)
    }
}
