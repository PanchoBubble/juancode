import Testing
@testable import JuancodeCore

/// A chain's badge color comes from its slug alone, and must not move between
/// launches, surfaces or themes.
@Suite struct ChainPaletteTests {
    @Test func theHashIsFnv1aAndNotTheSeededHashValue() {
        // The published FNV-1a 64-bit vectors: a seeded hash would fail these on
        // every run, and a changed constant would recolor every existing chain.
        #expect(ChainPalette.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(ChainPalette.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(ChainPalette.fnv1a("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test func aSlugKeepsItsHueInBothThemes() {
        for slug in ["ship-it", "auth-rework", "q4-launch"] {
            let light = ChainPalette.tone(for: slug, dark: false)
            let dark = ChainPalette.tone(for: slug, dark: true)
            #expect(light.hue == dark.hue)
            #expect(light.hue == ChainPalette.hues[ChainPalette.slot(for: slug)])
            #expect(ChainPalette.tone(for: slug, dark: false) == light)
            // Darker on white, brighter on black: the text has to read on both.
            #expect(light.brightness < dark.brightness)
        }
    }

    @Test func slugsSpreadOverThePalette() {
        let slots = Set((0..<200).map { ChainPalette.slot(for: "chain-\($0)") })
        #expect(slots == Set(ChainPalette.hues.indices))
        #expect(ChainPalette.hues.allSatisfy { (0..<1).contains($0) })
    }
}
