import Foundation
import Testing
@testable import JuancodeCore

/// Chain notes share one file with the sidecar (chain-notes.ts): the app must read
/// its lines, append in the same shape, and refuse ids that leave the directory.
@Suite struct ChainNotesTests {
    @Test func readsSidecarLinesAndAppendsInTheSameShape() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "c0ffee00-1111-2222-3333-444455556666"
        // Exactly what the sidecar writes, plus a torn line.
        let sidecar = #"{"author":"sess-1","kind":"summary","text":"half done","authorName":"worker","at":5}"#
            + "\n{\"broken\"\n"
        try sidecar.write(to: ChainNotes.file(chainId: id, in: dir)!, atomically: true, encoding: .utf8)

        try ChainNotes.append(chainId: id, text: "  check the flaky test  ", in: dir)
        let notes = ChainNotes.read(chainId: id, in: dir)
        #expect(notes.map(\.text) == ["half done", "check the flaky test"])
        #expect(notes[0].isSummary && notes[0].authorName == "worker")
        #expect(notes[1].byYou && notes[1].kind == "note" && notes[1].at > 0)
    }

    @Test func refusesIdsThatLeaveTheDirectory() {
        #expect(ChainNotes.file(chainId: "../x") == nil)
        #expect(ChainNotes.file(chainId: ".hidden") == nil)
        #expect(ChainNotes.file(chainId: "a/b") == nil)
        #expect(ChainNotes.file(chainId: "ok-id_1.2") != nil)
    }
}
