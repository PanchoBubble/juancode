import Foundation
import Testing

@testable import JuancodeCore

@Suite struct CursorProviderTests {
    @Test func launchContract() {
        let spec = Providers.spec(for: .cursor)
        #expect(Providers.all[.cursor] != nil)
        #expect(!spec.pinsSessionId)
        #expect(spec.startArgs("our-id", SpawnOptions()) == [])
        let opts = SpawnOptions(skipPermissions: true, model: "chosen-model")
        #expect(spec.startArgs("our-id", opts) == ["--force", "--sandbox", "disabled", "--model", "chosen-model"])
        #expect(spec.resumeArgs("chat-id", opts) == ["--resume", "chat-id", "--force", "--sandbox", "disabled", "--model", "chosen-model"])
    }
}
