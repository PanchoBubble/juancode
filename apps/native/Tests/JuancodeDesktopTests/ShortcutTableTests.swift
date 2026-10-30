import Testing
@testable import JuancodeDesktop

/// The panel-focus layout moved ⌘⇧P (HUD → PRs) and ⌘⇧C (current changes →
/// Chains). These pin the two rules that decide whether a user's stored shortcuts
/// survive that: the one-shot migration and who owns a shared chord.
@Suite struct ShortcutTableTests {
    private let displaced = ["togglePerfHud": "⇧⌘P", "openChangesForCurrentSession": "⇧⌘C"]

    @Test func storedOldDefaultsMigrateToTheNewDefault() {
        // "Reset All" persists every action, so a stock install stores old defaults.
        let stored = ["togglePerfHud": "⇧⌘P", "openChangesForCurrentSession": "⇧⌘C", "quickOpen": "⌘P"]
        let migrated = ShortcutTable.migrateDisplacedDefaults(stored, displaced: displaced)
        #expect(migrated == ["quickOpen": "⌘P"])
    }

    @Test func customChoicesSurviveTheMigration() {
        let stored = ["togglePerfHud": "⌃⌘H", "openChangesForCurrentSession": "⇧⌘C", "jumpPalette": "⇧⌘S"]
        let migrated = ShortcutTable.migrateDisplacedDefaults(stored, displaced: displaced)
        #expect(migrated == ["togglePerfHud": "⌃⌘H", "jumpPalette": "⇧⌘S"])
    }

    @Test func aCustomBindingOwnsTheChordOverANewDefault() {
        // The user bound Jump to ⇧⌘S before ⇧⌘S became Focus Sessions' default.
        let effective = ["focusSessionsPanel": "⇧⌘S", "jumpPalette": "⇧⌘S", "quickOpen": "⌘P"]
        let custom: Set = ["jumpPalette"]
        let owner = ShortcutTable.owner(
            of: "⇧⌘S", order: ["focusSessionsPanel", "jumpPalette", "quickOpen"],
            effective: { effective[$0]! }, isCustom: custom.contains)
        #expect(owner == "jumpPalette")
    }

    @Test func betweenEqualsTheFirstActionWins() {
        let owner = ShortcutTable.owner(
            of: "⌘P", order: ["a", "b"], effective: { _ in "⌘P" }, isCustom: { _ in false })
        #expect(owner == "a")
        #expect(ShortcutTable.owner(of: "⌘X", order: ["a"], effective: { _ in "⌘P" },
                                    isCustom: { _ in false }) == nil)
    }
}
