import Foundation
import Testing
@testable import JuancodeCore

/// The porcelain-status parser backing the groundwork file-tree / Quick Open model.
@Suite struct WorktreeStatusTests {
    @Test func parsesStagedUnstagedAndUntracked() {
        let raw = """
        M  src/a.swift
         M src/b.swift
        ?? new.txt
        """
        let entries = parseWorktreeStatus(raw)
        #expect(entries.count == 3)
        #expect(entries[0].path == "src/a.swift")
        #expect(entries[0].index == "M")
        #expect(entries[0].workTree == " ")
        #expect(entries[1].index == " ")
        #expect(entries[1].workTree == "M")
        #expect(entries[2].untracked)
    }

    @Test func parsesRenameWithArrow() {
        let entries = parseWorktreeStatus("R  old/name.swift -> new/name.swift")
        #expect(entries.count == 1)
        #expect(entries[0].path == "new/name.swift")
        #expect(entries[0].origPath == "old/name.swift")
        #expect(entries[0].index == "R")
    }

    @Test func emptyStatusIsNoEntries() {
        #expect(parseWorktreeStatus("").isEmpty)
        #expect(parseWorktreeStatus("\n\n").isEmpty)
    }
}
