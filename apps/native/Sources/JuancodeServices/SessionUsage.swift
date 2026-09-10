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
///   - opencode tallies tokens *and* cost onto its session row as it goes, so
///     `OpencodeStore` just reads them (its cost is the CLI's own, not our estimate).
///
/// Alongside the cumulative totals each provider reports, the newest turn also
/// gives *context pressure* (juancode-lncw): what the live conversation currently
/// occupies of the model's window, which is what actually runs out. It is the
/// newest turn's input + cache tokens (Codex names it outright), never a sum.
///
/// Cost is a best-effort *estimate* from published per-MTok rates (`ModelPricing`
/// in JuancodeCore). For a
/// model we have no price for — or Codex, which doesn't expose a per-token
/// price (and is usually a subscription) — `costUsd` is nil and only tokens are
/// shown. Subscription users pay nothing per token regardless, so the figure is
/// labelled an estimate in the UI.
///
/// Returns nil when no usage is available yet (e.g. before the first turn).

/// Override the transcript roots (used by tests to point at fixtures).
public struct UsageRoots {
    public var claudeProjects: String?
    public var codexSessions: String?
    /// opencode's database file (it keeps no per-session transcript); nil uses
    /// `OpencodeStore.defaultPath`.
    public var opencodeDb: String?
    public init(claudeProjects: String? = nil, codexSessions: String? = nil,
                opencodeDb: String? = nil) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
        self.opencodeDb = opencodeDb
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
    /// Context occupancy of the newest counted turn — its input + cache read +
    /// cache write, i.e. what the next request has to re-send (juancode-lncw).
    /// Replaced, never summed: the running total says what the session has spent,
    /// this says how full it is right now.
    var contextTokens: Int?
    /// Window of the newest counted turn's model, nil for an unknown model.
    var contextWindow: Int?

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
            costUsd: costKnown ? costUsd : nil,
            contextTokens: contextTokens,
            contextWindow: contextWindow)
    }
}

/// The cumulative tally Codex reports, carried across polls for the same reason.
private struct CodexTotals {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var totalTokens = 0
    /// From the same `token_count` event: what the last request sent, against the
    /// window the event reports for the model (juancode-lncw). Codex names both, so
    /// unlike Claude there is no model-id lookup involved — and when an older Codex
    /// omits them both stay nil and the UI just shows tokens.
    var contextTokens: Int?
    var contextWindow: Int?

    var usage: SessionUsage {
        SessionUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: 0,
            totalTokens: totalTokens,
            costUsd: nil,
            contextTokens: contextTokens,
            contextWindow: contextWindow)
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

    // Context pressure: the newest turn wins outright. A compaction shrinks it back
    // down, which is the whole point of tracking it separately from the totals.
    acc.contextTokens = input + cacheRead + cacheWrite
    acc.contextWindow = ModelPricing.contextWindow(for: model)

    if let cost = ModelPricing.turnCost(
        model: model, input: input, output: output,
        cacheRead: cacheRead, cacheWrite: cacheWrite) {
        acc.costUsd += cost
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
                  info["total_token_usage"] is [String: Any] else { return nil }
            latest = codexTotals(from: info)
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
        var info: [String: Any]? = nil
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
               let infoBlock = payload?["info"] as? [String: Any],
               infoBlock["total_token_usage"] is [String: Any] {
                info = infoBlock
            }
            return nil
        }
        if isMatch {
            fileCache.set(cliSessionId, full)
            guard let t = info else { return nil }  // matched the session but no turn has run yet
            let totals = codexTotals(from: t)
            usageState.setCodex(cliSessionId, totals)
            return totals.usage
        }
    }
    return nil
}

/// Read a Codex `token_count` info block into totals. Its cumulative
/// `total_token_usage.input_tokens` already includes the cached portion, so the
/// cached tokens are subtracted out to report fresh input separately. Codex
/// exposes no per-token price, so cost stays nil (see `CodexTotals.usage`).
///
/// `last_token_usage` (what the newest request actually sent) and
/// `model_context_window` sit beside the cumulative block and give context
/// pressure directly — both optional, so an older Codex just reports no context.
private func codexTotals(from info: [String: Any]) -> CodexTotals {
    let total = info["total_token_usage"] as? [String: Any] ?? [:]
    let cacheRead = intField(total, "cached_input_tokens")
    let input = max(0, intField(total, "input_tokens") - cacheRead)
    let output = intField(total, "output_tokens")
    let window = intField(info, "model_context_window", -1)
    let last = info["last_token_usage"] as? [String: Any]
    let lastInput = last.map { intField($0, "input_tokens", -1) } ?? -1
    return CodexTotals(
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        totalTokens: intField(total, "total_tokens", input + output + cacheRead),
        contextTokens: lastInput >= 0 ? lastInput : nil,
        contextWindow: window > 0 ? window : nil)
}

public func deriveSessionUsage(
    _ provider: ProviderId,
    _ cliSessionId: String,
    _ roots: UsageRoots = UsageRoots()
) async -> SessionUsage? {
    switch provider {
    case .claude:
        return await deriveClaudeUsage(cliSessionId, roots.claudeProjects ?? CLAUDE_PROJECTS)
    case .codex:
        return await deriveCodexUsage(cliSessionId, roots.codexSessions ?? CODEX_SESSIONS)
    case .opencode:
        // opencode keeps running totals — and its own cost figure — on the session row,
        // so there is nothing to accumulate or dedup here.
        return OpencodeStore.usage(cliSessionId, db: roots.opencodeDb ?? OpencodeStore.defaultPath)
    }
}
