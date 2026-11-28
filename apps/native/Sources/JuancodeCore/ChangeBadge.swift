import Foundation

/// A count shortened to fit a badge: `938`, `1.2k`, `12k`, `3.4M`. One decimal
/// below ten of a unit, whole numbers above — a glance, not a ledger.
public func compactCount(_ n: Int) -> String {
    let magnitude = abs(n)
    if magnitude < 1000 { return "\(n)" }
    let sign = n < 0 ? "-" : ""
    func scaled(_ divisor: Double, _ suffix: String) -> String {
        let v = Double(magnitude) / divisor
        // 9.95 rather than 10: anything that would print as "10.0" belongs in the
        // whole-number form.
        let text = v < 9.95 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return sign + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
    // 999_500 rounds to 1000k, which is a megabyte-shaped lie — hand it to M.
    return magnitude < 999_500 ? scaled(1000, "k") : scaled(1_000_000, "M")
}

/// A deterministic fingerprint of a `git status --porcelain` name-status list.
/// Sorted so a mere re-ordering never re-badges — only an added/removed path or a
/// changed status code shifts it, which is exactly "the diff changed since I last
/// looked".
public func changeStatSignature(_ entries: [WorktreeStatusEntry]) -> String {
    entries
        .map { "\($0.index)\($0.workTree) \($0.origPath.map { $0 + " -> " } ?? "")\($0.path)" }
        .sorted()
        .joined(separator: "\n")
}

/// Whether a settle edge should recompute a session's review badge. The review
/// moment is a non-editor agent finishing a turn: a real `busy → idle`/`waiting`
/// boundary (`notify`), not a teardown reset or a mid-turn flicker.
public func shouldComputeChangeBadge(prev: SessionActivity?, next: SessionActivity,
                                     notify: Bool, isEditor: Bool) -> Bool {
    if isEditor { return false }
    guard notify else { return false }
    return prev == .busy && next != .busy
}

/// Whether a computed stat should surface as a badge, given what the session's
/// Changes panel last showed. Hidden when clean or unchanged since last viewed.
public func changeBadgeVisible(latest: ChangeStat?, viewedSignature: String?) -> Bool {
    guard let latest, !latest.isEmpty else { return false }
    return latest.signature != viewedSignature
}
