import Testing
@testable import JuancodeApp

@Suite struct HintShortcutTests {
    @Test func defaultIsControlFAndNoOtherDefaultUsesIt() {
        let binding = ShortcutAction.hintMode.defaultBinding
        #expect(binding == KeyBinding(key: "f", control: true))
        #expect(binding.isBound)
        // A factory default must never collide with another one, or one of the two
        // would silently lose its key.
        let sharing = ShortcutAction.allCases.filter { $0.defaultBinding == binding }
        #expect(sharing == [.hintMode])
    }

    @Test func hintShortcutIsNotAFixedKey() {
        #expect(!FixedShortcut.all.contains { $0.binding == ShortcutAction.hintMode.defaultBinding })
    }
}
