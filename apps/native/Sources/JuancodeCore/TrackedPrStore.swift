import Foundation

/// Persistence seam for the tracked-PR watch list (juancode-b4m). Payload-based
/// (id → JSON-encoded `TrackedPr`) because JuancodePersistence depends only on
/// JuancodeCore and can't see the `TrackedPr` type in JuancodeServices — the
/// encode/decode stays in the caller (`PrTrackingEngine`, the single owner of
/// the list). The list is small and always written whole, so the API is a
/// whole-list replace in one transaction rather than per-row upserts.
public protocol TrackedPrStore: Sendable {
    /// All persisted tracked PRs, keyed by `TrackedPr.key(cwd:number:)`.
    func loadTrackedPrPayloads() -> [String: String]
    /// Replace the whole persisted watch list atomically (delete-all + insert).
    func replaceTrackedPrPayloads(_ payloads: [String: String])
}
