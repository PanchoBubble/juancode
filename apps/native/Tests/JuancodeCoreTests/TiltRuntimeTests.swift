import Testing
@testable import JuancodeCore

@Suite struct TiltRuntimeTests {
    @Test func listenersOnlyMatchTiltAndDeduplicateSockets() {
        #expect(TiltRuntime.tiltPids("p42\nctilt\nf9\np42\nctilt\nf10\np51\ncnode\np62\nctilt-helper\np71\nctilt\n") == [42, 71])
        #expect(TiltRuntime.tiltPids("").isEmpty)
    }
}
